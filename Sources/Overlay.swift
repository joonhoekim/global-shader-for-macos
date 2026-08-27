import AppKit
import QuartzCore

// One window covering a whole display, holding nothing but a CAMetalLayer.
//
// Hyprland's screen shader is one more pass by the compositor at the end, so there is
// no window involved. macOS has no such hook in the window server, so "the window on
// top of everything" stands in for it — capture what is below, run the shader, draw it
// back on top.

final class OverlayWindow: NSWindow {
    // This window must never take focus. If it did, keystrokes for the app you were
    // actually using would stop arriving.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(screen: NSScreen, layer: CAMetalLayer, capturable: Bool) {
        self.init(contentRect: screen.frame, styleMask: .borderless,
                  backing: .buffered, defer: false, screen: screen)

        // Every click falls straight through. This one line is all of "the screen is
        // covered but still usable". The menu bar and the Dock stay alive underneath, so
        // what you see is what you can press — part of why the status item works as an
        // escape hatch.
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black

        // This window is captured by nobody.
        //
        // Excluding our app from our own stream (Capture.swift) is not enough.
        // excludingApplications works per SCRunningApplication — that is, per
        // **process** — so a second process of the same app is not excluded. With two
        // up, they capture each other's overlay, feedback runs, and the screen converges
        // on a strange picture (measured with --diag, the marker reads back at 74–100%).
        //
        // sharingType is a property of the window itself, so it holds no matter who is
        // capturing — a second instance, another recorder, anything. The instance lock
        // (main.swift) is the first defence; this is the structural one.
        //
        // The price: screenshots and screen recordings do not carry the shader. They come
        // out as the original screen. Better than a screen falling apart from feedback,
        // and there is a case for liking a clean screenshot. --capturable turns it off.
        sharingType = capturable ? .readOnly : .none
        hasShadow = false
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true

        // CGShieldingWindowLevel() is above the menu bar and notifications alike. Matching
        // what Hyprland does, where the bar and tray go behind the same glass, means being
        // here. Dropping to .screenSaver puts notifications outside the shader.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

        // canJoinAllSpaces + stationary: follows you across Spaces without being dragged
        // along by the switch animation.
        // fullScreenAuxiliary: stays on top of another app in full screen.
        // ignoresCycle: stays out of the Cmd+` cycle.
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = layer
        layer.frame = view.bounds
        layer.contentsScale = screen.backingScaleFactor
        contentView = view
    }

    // ── Covering our own UI ──────────────────────────────────────────────
    //
    // CGShieldingWindowLevel() is 2147483628, while a menu's dropdown window is 101
    // (kCGPopUpMenuWindowLevel) and NSAlert and NSOpenPanel are 8 (modalPanel). That is,
    // **the menu you get by clicking the status item is laid under the overlay.** Cover
    // the screen in red, open the menu, take a screenshot: not one pixel of the menu.
    //
    // The ◲ in the menu bar stayed visible throughout, because the menu bar belongs to
    // the window server and is therefore **in the capture**, showing through the glass.
    // The dropdown belongs to our app, so it is out of the capture (per-app exclusion in
    // Capture.swift) and below in level — neither drawn nor shown through.
    //
    // The answer is to lower the overlay below popUpMenu only while a menu is open. At
    // 100 it still covers ordinary windows (0), floating windows (3), modal panels (8),
    // and the menu bar (24), so the only thing that changes is our own menu. Dialogs go
    // the other way and raise their own level above shielding (MenuController).
    //
    // That the menu does not get the glass is accepted. This window's premise is that you
    // can escape through here even when the shader has made the screen unreadable, so the
    // control panel had better be legible.
    static let menuSafeLevel = NSWindow.Level(rawValue: 100)

    func setBelowMenus(_ below: Bool) {
        let want = below ? OverlayWindow.menuSafeLevel
                         : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        if level != want { level = want }
    }

    /// Follow a change in display layout.
    func resync(to screen: NSScreen) {
        setFrame(screen.frame, display: false)
        contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        if let l = contentView?.layer {
            l.frame = contentView!.bounds
            l.contentsScale = screen.backingScaleFactor
        }
    }
}

/// One set per display: window + renderer + capture.
final class DisplaySurface {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let window: OverlayWindow
    let renderer: Renderer
    var capture: DisplayCapture?

    // The window goes up **after the first frame is drawn**. Up any earlier and the whole
    // screen is covered by a black window while permission is missing or capture has not
    // started — which is exactly when something is wrong, and the screen you would go fix
    // it on disappears along with it.
    var isPresented = false

    init?(screen: NSScreen, device: MTLDevice, capturable: Bool, vsync: Bool = true) {
        guard let id = screen.displayID,
              let r = Renderer(device: device, vsync: vsync) else { return nil }
        self.screen = screen
        self.displayID = id
        self.renderer = r
        self.window = OverlayWindow(screen: screen, layer: r.layer, capturable: capturable)
    }

    /// Pixel size of the capture and the drawable.
    ///
    /// **The backing store, not the panel resolution.** In a scaled mode like "More
    /// Space", macOS draws the desktop into a backing store (2940x1912, say) and then
    /// shrinks it to the panel (2560x1664). Our layer is composited into that same
    /// backing store, so drawing at panel size means scaling up and back down again,
    /// which is blurrier. It costs 26% more pixels and it is the right call.
    ///
    /// scale is the knob for paying less of that price by hand (--scale).
    func pixelSize(scale: Double = 1.0) -> CGSize {
        let s = screen.backingScaleFactor * CGFloat(scale)
        return CGSize(width: (screen.frame.width * s).rounded(),
                      height: (screen.frame.height * s).rounded())
    }

    /// The cursor as 0..1 coordinates within this display, top-left origin. It has to be
    /// the same coordinate system pointer_position meant under Hyprland.
    ///
    /// CGEvent rather than NSEvent.mouseLocation because this value is read **on the
    /// capture queue**. CGEvent's location does not care which thread asks, and as a
    /// bonus it is already top-left origin, so there is nothing to flip (NSEvent is
    /// bottom-left).
    var pointerInScreen: SIMD2<Float> {
        let b = CGDisplayBounds(displayID)
        guard let p = CGEvent(source: nil)?.location else { return SIMD2(0.5, 0.5) }
        return SIMD2(Float((p.x - b.minX) / max(b.width, 1)),
                     Float((p.y - b.minY) / max(b.height, 1)))
    }
}

// The last 32 clicks. To mean what addLastPressToHistory means under Hyprland, [0] is
// the most recent, and the times a shader receives are not absolute — they are **seconds
// elapsed since**.
//
// Coordinates are kept global (display layout) and normalized per display on read. That
// is simpler than remembering which display a click landed on, and Hyprland likewise
// gives each output the same history in its own coordinates.
final class ClickHistory {
    private let lock = NSLock()
    private var entries: [(global: CGPoint, at: CFTimeInterval)] = []
    private var monitors: [Any] = []

    func start() {
        // A global monitor for mouse events needs no Accessibility permission — that is
        // for key events. Which is why a shader does not have to ask for input monitoring.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.record()
        }) { monitors.append(m) }
    }

    private func record() {
        guard let p = CGEvent(source: nil)?.location else { return }
        lock.lock(); defer { lock.unlock() }
        entries.insert((p, CACurrentMediaTime()), at: 0)
        if entries.count > GSGlobals.historyCount { entries.removeLast() }
    }

    /// Positions normalized to this display, and seconds elapsed since each click.
    func snapshot(for displayID: CGDirectDisplayID) -> [(pos: SIMD2<Float>, age: Float)] {
        let b = CGDisplayBounds(displayID)
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        return entries.map {
            (SIMD2(Float(($0.global.x - b.minX) / max(b.width, 1)),
                   Float(($0.global.y - b.minY) / max(b.height, 1))),
             Float(now - $0.at))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    // maximumFramesPerSecond is the current API, and it accounts for variable refresh
    // (ProMotion). CGDisplayMode.refreshRate is known to return 0 on built-in ProMotion
    // panels, which would cut a 120Hz display to 60. The split does not show on 60Hz
    // hardware (both give 60), so it is **unverified on ProMotion.**
    var refreshRate: Int {
        if maximumFramesPerSecond > 0 { return maximumFramesPerSecond }
        if let id = displayID, let m = CGDisplayCopyDisplayMode(id), m.refreshRate > 0 {
            return Int(m.refreshRate.rounded())
        }
        return 60
    }
}
