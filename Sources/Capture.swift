import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

// Captures one display continuously and hands the frames on.
//
// Stopping the feedback of capturing ourselves is what this file is about. The
// SCContentFilter excludes **per app** (not per window). Excluding a window means
// getting an SCWindow first, and that only appears in the list after the window is
// up, and has to be found again on every display change. The only windows this app
// puts up are the overlays and the status item, so excluding the whole app is simpler
// and sturdier.

protocol CaptureDelegate: AnyObject {
    func capture(_ capture: DisplayCapture, didOutput pixelBuffer: CVPixelBuffer)
    func capture(_ capture: DisplayCapture, didFailWith error: Error)
}

// @unchecked Sendable is not a concession on safety; it stands for one piece of
// discipline the compiler cannot see: the mutable state of this class (lastBuffer,
// redrawTimer, continuous) is touched **only on the queue below**. start() is async,
// so hopping to the queue inside it captures self, and the compiler has no way to
// verify the rule.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    let displayID: CGDirectDisplayID
    weak var delegate: CaptureDelegate?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "gs.capture", qos: .userInteractive)
    private let pixelSize: CGSize
    private let fps: Int
    /// Whether to keep drawing a still screen. Decided automatically from whether the
    /// shader reads time (--redraw auto), and follows a hot-reloaded shader.
    private var continuous: Bool

    // For redrawing a still screen. These two are touched only on the capture queue —
    // the timer runs on the same queue, so no lock is needed.
    private var lastBuffer: CVPixelBuffer?
    private var redrawTimer: DispatchSourceTimer?

    init(displayID: CGDirectDisplayID, pixelSize: CGSize, fps: Int, continuous: Bool) {
        self.displayID = displayID
        self.pixelSize = pixelSize
        self.fps = fps
        self.continuous = continuous
    }

    /// For when a shader change flipped the decision. Callable from any thread — the
    /// timer and lastBuffer are all touched on the capture queue.
    func setContinuous(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.continuous != on else { return }
            self.continuous = on
            if on { self.startRedrawTimerLocked() }
            else {
                self.redrawTimer?.cancel()
                self.redrawTimer = nil
            }
        }
    }

    /// Push the last frame through once more, even with nothing changed on screen.
    ///
    /// With redraw off, a still screen means no frames arrive at all. Dragging a knob
    /// or changing the chain in that state does **nothing** — the value changed, but
    /// there is no occasion to draw. To the eye it is indistinguishable from a broken
    /// slider, and that is the worst failure this app has (see the control socket).
    ///
    /// So lastBuffer is held regardless of continuous. queueDepth is 3, so holding one
    /// frame still leaves two in the stream.
    func nudge() {
        queue.async { [weak self] in
            guard let self, let buf = self.lastBuffer else { return }
            self.delegate?.capture(self, didOutput: buf)
        }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "gs", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Str.capture_err_noDisplay(Int(displayID))])
        }

        // Choosing what to exclude. Find ourselves by pid, and if there is a bundle ID,
        // exclude **other processes of the same bundle** along with it.
        //
        // The second case is one the instance lock already stops, but it is a free extra
        // layer — excludingApplications being per-process is the root of two-instance
        // feedback (see the sharingType note in Overlay.swift), and defences are better
        // stacked.
        //
        // **An empty string must never match.** bundleIdentifier on SCRunningApplication
        // can be empty (running the bare binary directly does that), and comparing against
        // an empty value would exclude other people's process from the capture too,
        // punching a hole in the screen.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier ?? ""
        var excluded = content.applications.filter { $0.processID == myPID }
        if !myBundle.isEmpty {
            let already = Set(excluded.map(\.processID))
            excluded += content.applications.filter {
                $0.bundleIdentifier == myBundle && !already.contains($0.processID)
            }
        }
        DiagLog.shared.note(excluded.isEmpty
            ? Str.capture_diag_notExcluded(Int(myPID))
            : Str.capture_diag_excluded(
                excluded.count,
                excluded.map { String($0.processID) }.joined(separator: ","),
                myBundle))

        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = Int(pixelSize.width)
        cfg.height = Int(pixelSize.height)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // Paired with bgra8Unorm in Renderer. The point is a round trip that does not
        // touch gamma-encoded values; the reason is in the pixelFormat note in Renderer.swift.
        cfg.colorSpaceName = CGColorSpace.sRGB
        // The cursor is not captured. Capturing it would double it up against the real
        // cursor the window server draws above the overlay. The cursor alone therefore
        // goes unshaded, which is the better trade — it rides on hardware rather than
        // through compositing, and pulling it in here is the one place latency shows.
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.scalesToFit = false
        cfg.capturesAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        queue.async { [weak self] in
            guard let self, self.continuous else { return }
            self.startRedrawTimerLocked()
        }
    }

    func stop() async {
        redrawTimer?.cancel()
        redrawTimer = nil
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        queue.sync { lastBuffer = nil }
    }

    // Push the last frame through the same shader again with nothing changed on screen.
    // Without this, a shader that runs on time (grain, hum bar, click ripples in
    // crt.frag) only advances a step when there is input — the same problem as having
    // to turn off debug:vfr under Hyprland, and the same price: a still screen keeps
    // the GPU busy at the refresh rate.
    private func startRedrawTimerLocked() {
        guard redrawTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(fps, 1))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let buf = self.lastBuffer else { return }
            self.delegate?.capture(self, didOutput: buf)
        }
        t.resume()
        redrawTimer = t
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb) else { return }

        // With nothing changed on screen, SCK hands back an empty frame with status
        // .idle. Drawing that gives a black screen for want of a texture, so only
        // .complete gets through.
        //
        // The price is that time stops on a still screen — the same thing Hyprland's
        // debug:vfr does to a moving shader, for the same reason. A shader that needs
        // motion resolves it through --redraw always (startRedrawTimer).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        // Held for redraw and nudge. queueDepth is 3, so holding one still leaves two
        // in the stream.
        lastBuffer = pb
        delegate?.capture(self, didOutput: pb)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        delegate?.capture(self, didFailWith: error)
    }
}
