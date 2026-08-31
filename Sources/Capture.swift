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
//
// ── A stream does not survive the display going away ─────────────────────
//
// Close the lid, or let the screen go dark on its own, and SCK ends the stream:
//
//   SCStreamErrorDomain code -3815  "Failed to find any displays or windows to capture"
//
// It is **ended, not paused.** Nothing resumes it on wake; the object stays alive and
// simply never hands over another frame. Measured with a bare stream and a one-second
// tick: frames stopped at the moment of display sleep and never came back, twenty
// seconds after the screen was awake again.
//
// On its own that would show as a screen that stops updating. What made it worse is
// the redraw timer below: it kept pushing `lastBuffer` — the frame from just before
// the lid closed — through the shader forever. The shader animated, so the app looked
// alive while the picture underneath it was a still from minutes ago. Meanwhile the
// window was ordered back to the front by that same stale frame, so hiding it did
// nothing either.
//
// So two things happen when a stream stops: painting stops with it (the timer is
// cancelled and the held frame dropped, or a dead picture would go on being drawn),
// and the capture tries to open a new stream — every half second for the first four,
// then backing off to five, for as long as someone still wants it running. While the
// display is asleep every attempt fails with the same -3815, which is free and
// correct: the one that lands after the screen comes back is the one that matters.

protocol CaptureDelegate: AnyObject {
    func capture(_ capture: DisplayCapture, didOutput pixelBuffer: CVPixelBuffer)
    /// The stream ended. The capture retries by itself — this is for the log and for
    /// taking the window down, so a dead stream does not leave a frozen picture up.
    func capture(_ capture: DisplayCapture, didFailWith error: Error)
    /// A retry got a stream back, after `attempts` failures.
    func capture(_ capture: DisplayCapture, didRestartAfter attempts: Int)
}

// @unchecked Sendable is not a concession on safety; it stands for one piece of
// discipline the compiler cannot see: the mutable state of this class (lastBuffer,
// redrawTimer, continuous, and the retry bookkeeping) is touched **only on the queue
// below**, except for the two values under liveLock, which main reads. start() is
// async, so hopping to the queue inside it captures self, and the compiler has no way
// to verify the rule.
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

    // Reopening after the stream ends. Queue-only, same rule as above.
    /// Whether anyone still wants this capture running. stop() clears it, and it is
    /// what makes the retry loop end rather than outlive the surface it belongs to.
    private var wantsRunning = false
    private var retryTimer: DispatchSourceTimer?
    private var retryDelay = 0.0
    private var attempts = 0
    /// One open at a time. A wake notification and a retry timer can arrive together.
    private var opening = false

    // Read from main (the status command, the stall watchdog), written on the capture
    // queue, so these two take the lock.
    private let liveLock = NSLock()
    private var lastLive: CFTimeInterval = 0
    private var restarts = 0

    /// Seconds since the stream last handed over a frame.
    ///
    /// **Redraw and nudge do not touch it.** Telling a stream that is delivering from
    /// a timer painting the same picture over and over is the whole point of the
    /// value — frame counters cannot do it, which is why the freeze after a lid close
    /// looked like a healthy 60 fps in `--status`.
    ///
    /// A still screen with redraw off legitimately produces nothing for minutes, so
    /// this is a number to report, not a number to restart on by itself.
    var secondsSinceLiveFrame: CFTimeInterval {
        liveLock.lock(); defer { liveLock.unlock() }
        return lastLive == 0 ? -1 : CACurrentMediaTime() - lastLive
    }

    /// How many times the stream had to be reopened. Shown in `--status`.
    var restartCount: Int {
        liveLock.lock(); defer { liveLock.unlock() }
        return restarts
    }

    // Both of these are called from async code, and taking a lock across an await is
    // an error in Swift 6 — but only when the lock is taken *in* the async function.
    // Neither of these ever suspends, so the pair is what keeps that true and visible.
    private func markLive() {
        liveLock.lock(); defer { liveLock.unlock() }
        lastLive = CACurrentMediaTime()
    }

    private func countRestart() {
        liveLock.lock(); defer { liveLock.unlock() }
        restarts += 1
    }

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
        queue.sync {
            wantsRunning = true
            retryTimer?.cancel()
            retryTimer = nil
            retryDelay = 0
            attempts = 0
        }
        do {
            try await open()
        } catch {
            // A capture that cannot start now is in the same position as one that
            // stopped: the display may simply be asleep at launch. Keep trying, and
            // still let the caller log the first failure.
            queue.async { self.scheduleRetryLocked() }
            throw error
        }
    }

    /// Tear the stream down and open a new one, now, without waiting for the backoff.
    ///
    /// For a wake notification. A stream that stopped and one that has merely gone
    /// quiet cannot be told apart from outside, so this does not try — a reopen costs
    /// one frame, and getting it wrong the other way is a frozen screen.
    ///
    /// The one case it does rule out is a stream that is plainly delivering. Waking
    /// posts **two** notifications (didWake and screensDidWake), and without this the
    /// second one would tear down the stream the first one just got back.
    func restartNow() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            let age = self.secondsSinceLiveFrame
            if age >= 0, age < 1.0 { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            // Back to the fast phase. A screen dark for an hour has run the attempt
            // count far past the point where the backoff settles at five seconds, and
            // waking is precisely the moment that count stops describing anything.
            self.retryDelay = 0
            self.attempts = 0
            Task { await self.attemptOpen() }
        }
    }

    func stop() async {
        queue.sync {
            wantsRunning = false
            retryTimer?.cancel()
            retryTimer = nil
            redrawTimer?.cancel()
            redrawTimer = nil
            lastBuffer = nil
        }
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    // MARK: Opening

    private func open() async throws {
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
        // Not a frame, but the moment the stream became answerable for delivering one.
        // Without it a fresh stream reads as infinitely stale until its first frame.
        markLive()
        queue.async { [weak self] in
            guard let self, self.continuous else { return }
            self.startRedrawTimerLocked()
        }
    }

    /// One attempt at a new stream. Runs off the queue; the bookkeeping hops back onto it.
    private func attemptOpen() async {
        let go: Bool = queue.sync {
            guard wantsRunning, !opening else { return false }
            opening = true
            return true
        }
        guard go else { return }

        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
        do {
            try await open()
            // stop() can have landed while this was opening — a display change during
            // a retry is exactly when that happens. It saw no stream to close, because
            // there was none yet, so closing it is this side's job. Otherwise the
            // surface goes away and its stream stays behind, still delivering.
            let (took, live): (Int, Bool) = queue.sync {
                opening = false
                retryDelay = 0
                let n = attempts
                attempts = 0
                return (n, wantsRunning)
            }
            guard live else {
                if let s = stream { try? await s.stopCapture(); stream = nil }
                return
            }
            countRestart()
            delegate?.capture(self, didRestartAfter: took)
        } catch {
            queue.async {
                self.opening = false
                self.attempts += 1
                self.scheduleRetryLocked()
            }
        }
    }

    /// Queue-only. Half a second, eight times over, and then backing off to five.
    ///
    /// The two ends of this want opposite things. A wake is the urgent end: the
    /// notification arrives **before the display is back** — measured at four failed
    /// attempts past it — and until one lands the screen is showing itself unshaded,
    /// so those first seconds have to be spent quickly. A screen that has been dark
    /// for an hour is the other end, and there half a second of polling for an hour
    /// is a battery cost for nothing.
    ///
    /// Four seconds of half-second tries covers the first case; what follows is for
    /// the second. The leeway follows the same split — coalescing is worth having once
    /// the delay is long, and would undo the point of the fast phase.
    private func scheduleRetryLocked() {
        guard wantsRunning, retryTimer == nil else { return }
        retryDelay = attempts < 8 ? 0.5 : min(max(retryDelay * 2, 1.0), 5.0)
        let t = DispatchSource.makeTimerSource(queue: queue)
        let leeway: DispatchTimeInterval =
            retryDelay >= 2 ? .seconds(2) : .milliseconds(100)
        t.schedule(deadline: .now() + retryDelay, leeway: leeway)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            Task { await self.attemptOpen() }
        }
        t.resume()
        retryTimer = t
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
        markLive()
        delegate?.capture(self, didOutput: pb)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stop painting before anything else. The frame in hand is from before the
        // screen went away, and the redraw timer would keep pushing it through the
        // shader — a picture that animates over a still from minutes ago, which reads
        // as the app working.
        queue.async { [weak self] in
            guard let self else { return }
            self.redrawTimer?.cancel()
            self.redrawTimer = nil
            self.lastBuffer = nil
            self.retryDelay = 0
            self.scheduleRetryLocked()
        }
        delegate?.capture(self, didFailWith: error)
    }
}
