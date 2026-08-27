import AppKit
import Metal

// global-shader — decoration:screen_shader, for macOS.
//
//   global-shader                                 the chain saved in settings
//   global-shader ~/.config/gs/shaders/crt.frag   apply one
//   global-shader crt.frag grain.frag             apply two, in order
//   global-shader --profile golden-era            a saved set
//
// One window per display. Each display is captured with ScreenCaptureKit, run
// through the chain, and drawn back into its own window. Why no other shape
// works is in docs/architecture.md.

/// What is not saved — flags that mean something only for this run.
struct LaunchFlags {
    var shaderPaths: [String] = []   // shaders from argv; their order is the chain order
    var profile: String?
    var diag = false                 // feedback probe: stamp a marker, read it back from capture
    var exitAfter: Double?           // quit after N seconds (for probes and measurement)
    var allowMultiple = false        // skip the instance lock (to reproduce feedback on purpose)
    var vsync = true                 // off means tearing, but the shader's real cost becomes visible
    var client: [String]?            // a control command for the instance already running
    var help = false
    var check = false                // translate only, then stop
    var dumpMSL = false              // print the translation
    var version = false
    var lang: String?                // language for this run; beats the setting
}

/// What the command line and the config file add up to.
///
/// One rule. **Shaders (chain, profile) persist; run options do not.**
///
/// `global-shader crt.frag` means "apply crt from now on", so it is written to
/// settings — changing the shader is changing your taste. `--scale 0.7` or
/// `--no-vsync`, on the other hand, is one measurement, not a change of taste.
/// Persisting those lets a single measurement quietly poison the settings. The
/// place to change taste is the menu, and what the menu changes persists.
struct Options {
    var flags = LaunchFlags()
    var runtime = RuntimeOptions()
    /// Run options actually written on the command line. They override the config file but are not saved.
    var explicit = Set<String>()
}

/// Shader paths from the command line, made absolute.
///
/// Without this, `global-shader shaders/crt.frag` is stored in settings as a
/// relative path, and that is only true **from this shell's current folder**.
/// At the next login launchd starts it with cwd `/` and the file is not there —
/// the kind of mismatch that surfaces the moment you add the login item, so it
/// is settled once, at the door.
func absolutePath(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    guard !(expanded as NSString).isAbsolutePath else { return expanded }
    let cwd = FileManager.default.currentDirectoryPath
    return ((cwd as NSString).appendingPathComponent(expanded) as NSString)
        .standardizingPath
}

func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    /// Mark a run option as overridden by the command line.
    func mark(_ k: String) { o.explicit.insert(k) }

    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-h", "--help": o.flags.help = true
        case "-V", "--version": o.flags.version = true
        case "--lang":
            i += 1
            // Silently ignoring an unknown value turns into "I passed --lang jp
            // and got English", which cannot be told apart from a typo.
            guard i < argv.count, let _ = Lang.match(argv[i]) else {
                let got = i < argv.count ? argv[i] : Str.word_none
                FileHandle.standardError.write(
                    (Str.cli_err_unknownLang(got, Lang.available) + "\n").data(using: .utf8)!)
                exit(2)
            }
            o.flags.lang = argv[i]
        case "--no-hot-reload": o.runtime.hotReload = false; mark("hotReload")
        case "--always-redraw": o.runtime.redraw = "always"; mark("redraw")   // old name
        case "--redraw":
            i += 1
            o.runtime.redraw = i < argv.count ? argv[i] : "auto"; mark("redraw")
        case "--diag": o.flags.diag = true; o.runtime.redraw = "always"; mark("redraw")
        case "--allow-multiple": o.flags.allowMultiple = true
        case "--capturable": o.runtime.capturable = true; mark("capturable")
        case "--knobs": o.runtime.knobs = true; mark("knobs")
        case "--no-knobs": o.runtime.knobs = false; mark("knobs")
        case "--no-vsync": o.flags.vsync = false
        case "--space-fix":
            i += 1
            o.runtime.spaceFix = i < argv.count ? argv[i] : "off"; mark("spaceFix")
        case "--profile":
            i += 1
            o.flags.profile = i < argv.count ? argv[i] : nil
        case "--stop":     o.flags.client = ["stop"]
        case "--reload":   o.flags.client = ["reload"]
        case "--get":      o.flags.client = ["list"]
        case "--status":   o.flags.client = ["status"]
        case "--chain":    o.flags.client = ["chain"]
        case "--profiles": o.flags.client = ["profile", "list"]
        case "--login":
            // on/off after it sets the value; nothing after it asks.
            if i + 1 < argv.count && (argv[i + 1] == "on" || argv[i + 1] == "off") {
                i += 1; o.flags.client = ["login", argv[i]]
            } else { o.flags.client = ["login", "status"] }
        case "--reset":
            // A name after it resets that one; nothing after it resets all.
            if i + 1 < argv.count && !argv[i + 1].hasPrefix("-") {
                i += 1; o.flags.client = ["reset", argv[i]]
            } else { o.flags.client = ["reset"] }
        case "--set":
            guard i + 2 < argv.count else {
                FileHandle.standardError.write((Str.cli_err_setNeedsArgs + "\n").data(using: .utf8)!)
                exit(2)
            }
            o.flags.client = ["set", argv[i + 1], argv[i + 2]]
            i += 2
        case "--exit-after":
            i += 1
            o.flags.exitAfter = i < argv.count ? Double(argv[i]) : nil
        case "--scale":
            i += 1
            o.runtime.scale = i < argv.count ? (Double(argv[i]) ?? 1.0) : 1.0
            o.runtime.scale = min(max(o.runtime.scale, 0.25), 1.0)
            mark("scale")
        case "--check": o.flags.check = true
        case "--dump-msl": o.flags.dumpMSL = true; o.flags.check = true
        case "--fps":
            i += 1
            o.runtime.fps = i < argv.count ? Int(argv[i]) : nil
            mark("fps")
        default:
            if a.hasPrefix("-") {
                FileHandle.standardError.write(
                    (Str.cli_err_unknownOption(a) + "\n").data(using: .utf8)!)
                exit(2)
            }
            // There can be several positional arguments, and their order is the chain order.
            o.flags.shaderPaths.append(absolutePath(a))
        }
        i += 1
    }
    return o
}


// MARK: -

final class App: NSObject, NSApplicationDelegate, CaptureDelegate {

    let flags: LaunchFlags
    /// The run options in force. The menu changes this and it persists to settings.
    private(set) var runtime: RuntimeOptions
    /// What the command line overrode. Until the menu changes it, this beats the config file.
    private let explicit: Set<String>

    private let device: MTLDevice
    private var surfaces: [DisplaySurface] = []
    private var statusItem: NSStatusItem?
    private var menuController: MenuController?
    private var watcher: DispatchSourceTimer?
    private let clicks = ClickHistory()
    let knobs = ChainKnobs()
    private var control: Control.Server?
    let store = ConfigStore.shared

    /// The chain in force. Kept identical to the one in the config file.
    private(set) var chain: [ChainEntry] = []
    /// Shaders switched off from the menu. The chain stays; a passthrough runs instead.
    private(set) var bypassed = false

    // The window right after a Space switch, while capture still hands back stale frames.
    private var suppressFramesUntil: CFTimeInterval = 0
    /// Redraw decision computed for the current chain.
    private var continuousRedraw = false
    /// (mtime, size) per file. Every slot in the chain is watched.
    private var stamps: [String: (Date, UInt64)] = [:]
    private(set) var status = Str.status_preparing
    /// Why capture never attached. Shown verbatim in the menu.
    private(set) var captureProblem: String?
    private var captureWatchdog: DispatchSourceTimer?
    /// Whether even one frame arrived. Written on the capture queue, read on main.
    private var sawFrame = false
    /// The last failure. Shown verbatim in the menu — launched without a terminal,
    /// stderr goes nowhere.
    private(set) var lastError: String?

    private var frames = 0
    private var probeSum = 0.0
    private var probeCount = 0
    private let launchedAt = CACurrentMediaTime()

    init(options: Options, device: MTLDevice) {
        self.flags = options.flags
        self.explicit = options.explicit
        self.device = device
        // The config file is the base; only what the command line names is laid over it.
        var r = ConfigStore.shared.config.options
        let cli = options.runtime
        if options.explicit.contains("fps")        { r.fps = cli.fps }
        if options.explicit.contains("scale")      { r.scale = cli.scale }
        if options.explicit.contains("redraw")     { r.redraw = cli.redraw }
        if options.explicit.contains("spaceFix")   { r.spaceFix = cli.spaceFix }
        if options.explicit.contains("knobs")      { r.knobs = cli.knobs }
        if options.explicit.contains("capturable") { r.capturable = cli.capturable }
        if options.explicit.contains("hotReload")  { r.hotReload = cli.hotReload }
        self.runtime = r
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Without Screen Recording permission SCShareableContent simply fails. Asking
        // first is what makes the prompt to System Settings appear.
        if !CGPreflightScreenCaptureAccess() {
            log(Str.log_needPermission)
            CGRequestScreenCaptureAccess()
        }

        // Decide the chain. The command line wins and persists to settings.
        if let name = flags.profile, let p = store.loadProfile(name) {
            chain = p.chain
            if let o = p.options { runtime = o }
            store.config.profile = name
            store.config.chain = chain
            store.save()
        } else if !flags.shaderPaths.isEmpty {
            chain = flags.shaderPaths.map { ChainEntry(path: ConfigStore.tildeAbbreviated($0)) }
            store.config.chain = chain
            store.config.profile = nil
            store.save()
        } else {
            chain = store.config.chain
        }

        makeStatusItem()
        clicks.start()
        // Decide redraw **before making the windows**. Capture takes this value when
        // it is created, so reversing the order starts the first chain with the wrong
        // one. Later hot reloads follow along through setContinuous.
        continuousRedraw = resolveRedraw()
        rebuildSurfaces()
        loadChain(initial: true)
        startWatching()
        if flags.diag {
            // The marker is drawn on top of the shader, so feedback is measured
            // against the chain that actually runs.
            for s in surfaces { s.renderer.drawsDiagMarker = true }
            status = Str.status_diag
        }
        if let sec = flags.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { NSApp.terminate(nil) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuildSurfaces() }

        startControl()
        watchSpaceChanges()
    }

    func applicationWillTerminate(_ n: Notification) {
        control?.stop()
        // Quitting mid-change is common (dragging a slider, then quitting). The
        // coalescing timer may not have fired, so write once, for certain, here.
        persistChain()
        store.save(immediately: true)
        for s in surfaces { s.window.orderOut(nil) }
        let dt = CACurrentMediaTime() - launchedAt
        log(Str.log_frames(frames, dt, Double(frames) / max(dt, 0.001)))
        if flags.diag {
            let avg = probeCount > 0 ? probeSum / Double(probeCount) : -1
            log(Str.log_probe(avg * 100, probeCount))
            log(avg > 0.5 ? Str.log_feedbackYes
                          : avg >= 0 ? Str.log_feedbackNo
                                     : Str.log_feedbackNoSamples)
        }
    }

    // MARK: One set per display

    private func rebuildSurfaces() {
        // A change in display layout rebuilds everything. There is no good API for
        // retuning a live stream to a new resolution, and this does not happen often.
        // Changing scale, fps, or screenshot visibility from the menu takes the same road.
        let old = surfaces
        surfaces = []
        Task { for s in old { await s.capture?.stop() }; await MainActor.run {
            for s in old { s.window.orderOut(nil) }
        } }

        for screen in NSScreen.screens {
            guard let surf = DisplaySurface(screen: screen, device: device,
                                            capturable: runtime.capturable,
                                            vsync: flags.vsync) else {
                log(Str.log_noRendererFor(screen.localizedName)); continue
            }
            let fps = runtime.fps ?? screen.refreshRate
            let size = surf.pixelSize(scale: runtime.scale)
            let cap = DisplayCapture(displayID: surf.displayID,
                                     pixelSize: size, fps: fps,
                                     continuous: continuousRedraw)
            cap.delegate = self
            surf.capture = cap
            surfaces.append(surf)
            if flags.diag { surf.renderer.drawsDiagMarker = true }

            let name = screen.localizedName
            Task {
                do { try await cap.start() } catch {
                    await MainActor.run {
                        self.log(Str.log_captureFailed(name, error.localizedDescription))
                    }
                }
            }
        }
        applyPassesToAll()
        startCaptureWatchdog()
    }

    // ── Capture that silently never attaches ─────────────────────────────
    //
    // The windows go up **only after the first frame arrives**. A full-screen
    // window left black without permission would take away the very screen you
    // need to fix it. But that safeguard means a capture that never attaches
    // shows nothing at all — no window, no error, just nothing happening.
    //
    // Which is easy to hit: rebuilding an ad-hoc signed app changes its cdhash,
    // TCC denies it, and the checkbox in System Settings stays on. "The
    // permission is clearly granted and it still does not work" — while stderr,
    // when launched from Finder, goes nowhere.
    //
    // So if no frame arrives within a few seconds, say so in the menu bar. That
    // is the only place a person can see it.
    private func startCaptureWatchdog() {
        captureWatchdog?.cancel()
        captureProblem = nil
        sawFrame = false
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 4.0)
        t.setEventHandler { [weak self] in
            guard let self, !self.sawFrame else { return }
            // Separate permission from everything else. The two need different fixes.
            self.captureProblem = CGPreflightScreenCaptureAccess()
                ? Str.capture_problem_notStarted
                : Str.capture_problem_denied
            self.log(self.captureProblem!)
            if !CGPreflightScreenCaptureAccess() {
                self.log(Str.capture_hint_adhoc(Ident.bundleID))
            }
            self.refreshStatusItem()
        }
        t.resume()
        captureWatchdog = t
    }

    /// Opens the Screen Recording pane in System Settings.
    func openScreenRecordingSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Draws one more frame even though the screen did not change.
    ///
    /// Without this, dragging a knob on a still screen does nothing. A shader with
    /// redraw off (`crt.frag`, which does not read time) only gets a frame when
    /// something on screen changes. A slider that moves while the picture does not
    /// reads as a broken slider.
    func nudge() {
        for s in surfaces { s.capture?.nudge() }
    }

    // MARK: Chain

    private var currentSpecs: [Renderer.PassSpec] = []

    /// The slots of the current chain that actually run.
    var activeEntries: [ChainEntry] { chain.filter { $0.enabled } }

    /// --redraw as an actual boolean. `auto` reads the chain's shaders.
    private func resolveRedraw() -> Bool {
        switch runtime.redraw {
        case "always": return true
        case "never":  return false
        default:
            // One slot reading time is enough. If a moving slot is not redrawn, it
            // does not look like that slot stopped — the whole chain looks frozen.
            //
            // But "reads time" and "is moving right now" are different. A shader can
            // gate its motion behind a knob (crt.frag), and then the source alone
            // does not answer: crt.frag with grain at 0 reads `time` and moves
            // nothing. So when a shader declares `!motion`, that value is consulted
            // first. Without the declaration, the source is all there is.
            let passes = knobs.snapshot()
            for (i, e) in activeEntries.enumerated() {
                guard let raw = try? String(contentsOfFile: expand(e.path), encoding: .utf8),
                      ShaderSource.needsContinuousRedraw(raw) else { continue }
                // passes is built in the same order as activeEntries, but the two can
                // drift — right after a failed translation. Trust it only when the paths match.
                if i < passes.count, passes[i].path == e.path,
                   let moving = ChainKnobs.motionGate(passes[i]) {
                    if moving { return true }
                    continue
                }
                return true
            }
            return false
        }
    }

    func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    /// Translate the chain and apply it.
    ///
    /// If any one slot fails, **nothing changes.** On first load it comes up with a
    /// passthrough; on reload the current chain stays. That a full-screen window must
    /// never be left black — you could not get to the typo to fix it — is this app's
    /// first rule.
    ///
    /// preferSeeds means "the values written in the chain beat the current ones". That
    /// is what applying a profile or swapping the chain wants — otherwise a shader
    /// present in two profiles keeps its values across a profile switch. The reload
    /// path, where a file was saved, wants the opposite: current values must survive.
    /// Editing an unrelated line of a shader must not move sliders you had set.
    func loadChain(initial: Bool, preferSeeds: Bool = false) {
        let entries = activeEntries
        guard !entries.isEmpty else {
            status = Str.status_noShader
            lastError = nil
            currentSpecs = []
            knobs.adopt([], seeds: [], preferSeeds: preferSeeds)
            for s in surfaces { s.renderer.usePassthrough() }
            refreshStatusItem()
            nudge()
            return
        }
        do {
            var specs: [Renderer.PassSpec] = []
            var parsed: [(path: String, knobs: [Knob], demoted: String?)] = []
            var seeds: [[String: Float]] = []
            for e in entries {
                let r = try ShaderSource.translate(path: expand(e.path), promoteKnobs: runtime.knobs)
                specs.append(Renderer.PassSpec(msl: r.msl, knobCount: r.knobs.count))
                parsed.append((path: e.path, knobs: r.knobs, demoted: r.demoted))
                seeds.append(e.knobs)
            }
            currentSpecs = specs
            knobs.adopt(parsed, seeds: seeds, preferSeeds: preferSeeds)
            try applyPasses(throwing: true)
            lastError = nil
            status = entries.map { ($0.path as NSString).lastPathComponent }
                            .joined(separator: " → ")

            // A changed chain re-decides redraw. Edit crt.frag to add grain and it
            // switches on the moment you save.
            let want = resolveRedraw()
            if want != continuousRedraw {
                continuousRedraw = want
                for s in surfaces { s.capture?.setContinuous(want) }
            }

            let n = parsed.reduce(0) { $0 + $1.knobs.count }
            let redrawWord = (continuousRedraw ? Str.word_on : Str.word_off)
                           + (runtime.redraw == "auto" ? Str.log_redrawAuto : "")
            log(Str.log_applied(status, redrawWord)
                + (n == 0 ? "" : Str.log_appliedKnobs(n)))
            for p in parsed where p.demoted != nil {
                log(Str.log_knobsDemoted((p.path as NSString).lastPathComponent, p.demoted!))
            }
        } catch {
            log(Str.log_applyFailed("\(error)"))
            lastError = "\(error)"
            if initial {
                for s in surfaces { s.renderer.usePassthrough() }
                status = Str.status_compileFailed
            }
        }
        refreshStatusItem()
        nudge()
    }

    private func applyPasses(throwing: Bool) throws {
        guard !bypassed else { return }
        for s in surfaces {
            do {
                try s.renderer.setPasses(currentSpecs)
                s.renderer.knobSource = { [weak self] i in self?.knobs.ordered(pass: i) ?? [] }
            } catch { if throwing { throw error } }
        }
    }

    private func applyPassesToAll() { try? applyPasses(throwing: false) }

    // MARK: Chain editing — the menu and the socket share this

    /// Swap the whole chain and persist it.
    ///
    /// Order matters. persistChain writes **the knobs in force** into the chain, so
    /// calling it *before* the new chain is applied stamps the old chain's values onto
    /// the new slots — which wipes the values a profile had frozen, right as it loads.
    func setChain(_ entries: [ChainEntry], profileName: String? = nil) {
        let previousChain = chain
        let previousProfile = store.config.profile
        chain = entries
        bypassed = false
        store.config.profile = profileName
        loadChain(initial: false, preferSeeds: true)

        // A chain that will not apply **is not persisted either.** Leaving the screen
        // alone is not enough — a broken slot left in config.json means the next run
        // takes the first-load path for that chain, and failing there comes up as a
        // passthrough. One typo would become a black screen at the next login, which
        // is the hardest kind of cause to trace back. The error stays, so the menu shows it.
        if lastError != nil {
            chain = previousChain
            store.config.profile = previousProfile
        }
        store.config.chain = chain
        // knobs now describes the current chain. Write back the values as clamped to range.
        persistChain()
        store.save()
        startWatching()
    }

    /// Write the current knob values into the chain. This is what lands in the config file.
    private func persistChain() {
        let active = activeEntries
        // Write only **while knobs actually describes the current chain.**
        //
        // A failed translation never reaches adopt, so knobs still holds the old chain.
        // Writing those values back by index would move a slider from an untouched
        // shader into the neighbouring slot over one typo. Checking that the two really
        // match, right here, cannot go stale the way a "did it fail" flag can.
        let snap = knobs.snapshot()
        guard snap.count == active.count,
              zip(snap, active).allSatisfy({ $0.path == $1.path }) else { return }
        var byIndex: [Int: [String: Float]] = [:]
        for i in active.indices { byIndex[i] = knobs.changedValues(pass: i) }
        var k = 0
        for i in chain.indices where chain[i].enabled {
            chain[i].knobs = byIndex[k] ?? [:]
            k += 1
        }
        store.config.chain = chain
    }

    /// Values only (a slider). Does not re-translate the chain.
    func knobsChanged() {
        persistChain()
        store.scheduleSave()

        // A knob marked `!motion` flips the redraw decision by changing value alone.
        // Drop GRAIN to 0 and a still screen stops redrawing from that moment; raise it
        // and it follows back on. Without this line the mark would be read once, at the
        // first translation, and lowering the slider would keep draining the battery.
        let want = resolveRedraw()
        if want != continuousRedraw {
            continuousRedraw = want
            for s in surfaces { s.capture?.setContinuous(want) }
            refreshStatusItem()
        }

        // Even when redraw was just switched off, one frame has to go through — showing
        // the changed picture comes first, and not drawing starts from the frame after.
        nudge()
    }

    func moveEntry(from: Int, to: Int) {
        guard chain.indices.contains(from), to >= 0, to < chain.count, from != to else { return }
        var next = chain
        let e = next.remove(at: from)
        next.insert(e, at: to)
        setChain(next, profileName: nil)
    }

    func removeEntry(at i: Int) {
        guard chain.indices.contains(i) else { return }
        var next = chain
        next.remove(at: i)
        setChain(next, profileName: nil)
    }

    func toggleEntry(at i: Int) {
        guard chain.indices.contains(i) else { return }
        var next = chain
        next[i].enabled.toggle()
        setChain(next, profileName: nil)
    }

    func appendShader(_ path: String) {
        var next = chain
        next.append(ChainEntry(path: ConfigStore.tildeAbbreviated(path)))
        setChain(next, profileName: nil)
    }

    // MARK: Profiles

    func applyProfile(_ name: String) -> String? {
        guard let p = store.loadProfile(name) else { return Str.profile_err_cannotRead(name) }
        if let o = p.options { applyRuntime(o) }
        setChain(p.chain, profileName: name)
        return nil
    }

    func saveProfile(_ name: String) -> String? {
        persistChain()
        if let why = store.saveProfile(name, Profile(chain: chain, options: runtime)) {
            return why
        }
        store.config.profile = name
        store.save()
        return nil
    }

    // MARK: Run options — what a change forces to be rebuilt

    func applyRuntime(_ new: RuntimeOptions) {
        let old = runtime
        runtime = new
        store.config.options = new
        store.save()

        // What only a rebuilt capture and window can reflect. Scale and fps are stream
        // settings; capturable is the sharingType fixed when the window is made.
        if old.scale != new.scale || old.fps != new.fps || old.capturable != new.capturable {
            continuousRedraw = resolveRedraw()
            rebuildSurfaces()
        } else if old.redraw != new.redraw {
            let want = resolveRedraw()
            if want != continuousRedraw {
                continuousRedraw = want
                for s in surfaces { s.capture?.setContinuous(want) }
            }
        }
        // A change in promotion has to go back through translation.
        if old.knobs != new.knobs { loadChain(initial: false) }
        if old.hotReload != new.hotReload { startWatching() }
        refreshStatusItem()
    }

    // MARK: File watching

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        stamps = [:]
        guard runtime.hotReload, !flags.diag else { return }
        let paths = activeEntries.map { expand($0.path) }
        guard !paths.isEmpty else { return }
        for p in paths { stamps[p] = stamp(of: p) }

        // Polling rather than kqueue, because of editors. vim and VS Code do not edit
        // the file on save; they write a new one and rename, so a watch holding an fd
        // is left looking at a dead inode after the first save. 0.4 s polling has no
        // such trap.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var changed = false
            for p in self.activeEntries.map({ self.expand($0.path) }) {
                let now = self.stamp(of: p)
                if now?.0 != self.stamps[p]?.0 || now?.1 != self.stamps[p]?.1 {
                    self.stamps[p] = now
                    changed = true
                }
            }
            if changed { self.loadChain(initial: false) }
        }
        t.resume()
        watcher = t
    }

    private func stamp(of path: String) -> (Date, UInt64)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let d = a[.modificationDate] as? Date,
              let sz = a[.size] as? NSNumber else { return nil }
        return (d, sz.uint64Value)
    }

    // MARK: Control socket

    private func startControl() {
        // An instance started with --allow-multiple does not open the socket.
        //
        // Control.Server.start() unlinks a stale socket file and binds. What makes that
        // safe is "the instance lock already guaranteed we are alone" — and this flag is
        // exactly the one that skips the lock. Left as is, a test instance would **steal
        // the socket of the real instance already running** and delete the file on the
        // way out. The remaining instance would keep running while answering neither
        // --status nor --stop.
        guard !flags.allowMultiple else {
            log(Str.log_allowMultipleNoSocket)
            return
        }
        let srv = Control.Server { [weak self] line in
            guard let self else { return "err shutting down" }
            return self.handle(line)
        }
        do { try srv.start(); control = srv }
        catch { log(Str.log_controlSocketFailed("\(error)")) }
    }

    /// One line in from the socket. Called on the main queue.
    ///
    /// Paths and profile names can contain spaces, so **the whole rest of the line**
    /// arrives as one piece. Several paths are separated by tabs — the same binary is
    /// also the client, so we can hold to that convention ourselves, and calling it by
    /// hand from a shell needs no quoting for a single path.
    private func handle(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 2,
                              omittingEmptySubsequences: false).map(String.init)
        let verb = parts.first ?? ""
        /// From the nth word to the end of the line.
        func rest(_ n: Int) -> String {
            let ws = line.split(separator: " ", maxSplits: n,
                                omittingEmptySubsequences: false).map(String.init)
            return ws.count > n ? ws[n].trimmingCharacters(in: .whitespaces) : ""
        }

        switch verb {
        case "list", "get":
            return knobs.json()

        case "set":
            let ws = line.split(separator: " ").map(String.init)
            guard ws.count >= 3, let v = Float(ws[2]) else { return "err usage: set NAME VALUE" }
            guard runtime.knobs else { return "err started with --no-knobs; there are no knobs" }
            if let why = knobs.set(ws[1], v) { return "err " + why }
            knobsChanged()
            return "ok"

        case "reset":
            let ws = line.split(separator: " ").map(String.init)
            if let why = knobs.reset(ws.count >= 2 ? ws[1] : nil) { return "err " + why }
            knobsChanged()
            return "ok"

        case "reload":
            loadChain(initial: false)
            return "ok"

        case "chain":
            return handleChain(sub: parts.count > 1 ? parts[1] : "", rest: rest(2))

        case "profile":
            return handleProfile(sub: parts.count > 1 ? parts[1] : "", rest: rest(2))

        case "login":
            // Menu-only would leave no way to check it. Writing a plist and calling
            // launchctl is the kind of work that fails quietly, so it has to be
            // answerable from outside.
            let sub = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch sub {
            case "", "status":
                switch LoginItem.state() {
                case .off: return "off"
                case .on:  return "on \(LoginItem.plistURL.path)"
                case .managedElsewhere(let l, let byNix):
                    return "managed \(l)\(byNix ? " (nix)" : "")"
                }
            case "on", "off":
                if let why = LoginItem.setEnabled(sub == "on") { return "err " + why }
                store.config.launchAtLogin = (sub == "on")
                store.save(immediately: true)
                return "ok"
            default:
                return "err usage: login [status|on|off]"
            }

        case "status":
            let dt = CACurrentMediaTime() - launchedAt
            // Built as one line. Swift's multi-line literal keeps **the indentation
            // whitespace** even with a trailing \ to remove the newline, which would put
            // a block of spaces in the middle of the JSON. Parsers tolerate it; eyes do not.
            let fps = String(format: "%.1f", Double(frames) / max(dt, 0.001))
            let prof = store.config.profile.map { "\"\($0)\"" } ?? "null"
            // Capture never attaching also shows as fps 0, but 0 can equally mean "before
            // the first frame". The app has already told the two apart, so pass that on.
            let cap = captureProblem.map {
                "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\""
            } ?? "null"
            // Version first. It is the first thing to ask about an issue, and with a hole
            // that already emits JSON, leaving it out means someone has to dig it up by hand.
            return "{\"version\":\"\(Build.version)\",\"build\":\"\(Build.number)\","
                 + "\"lang\":\"\(Lang.current.rawValue)\","
                 + "\"chain\":\(chainJSON()),\"profile\":\(prof),\"capture\":\(cap),"
                 + "\"passes\":\(activeEntries.count),\"knobs\":\(knobs.count),"
                 + "\"knobsEnabled\":\(runtime.knobs),\"bypassed\":\(bypassed),"
                 + "\"displays\":\(surfaces.count),\"scale\":\(runtime.scale),"
            // Whether redraw is on right now. fps cannot answer this — frames arrive when
            // the screen changes even with redraw off, and the fps above is the average
            // since launch, so something switched off a moment ago does not show.
            //
            // With motion gated behind a knob (`!motion` in crt.frag), this is the only
            // place that answers "why is a still screen using battery". mode comes along
            // because auto's own decision and an explicit --redraw override read differently.
                 + "\"redraw\":\(continuousRedraw),\"redrawMode\":\"\(runtime.redraw)\","
                 + "\"fps\":\(fps)}"

        case "stop":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok"

        default:
            return "err unknown command: \(line)"
        }
    }

    private func chainJSON() -> String {
        let items = chain.map { e -> String in
            let p = e.path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"path\":\"\(p)\",\"enabled\":\(e.enabled)}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func handleChain(sub: String, rest: String) -> String {
        switch sub {
        case "", "list": return chainJSON()
        case "set":
            let paths = rest.split(separator: "\t").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !paths.isEmpty else { return "err usage: chain set PATH[\\tPATH…]" }
            for p in paths where !FileManager.default.fileExists(atPath: expand(p)) {
                return "err no such file: \(p)"
            }
            setChain(paths.map { ChainEntry(path: ConfigStore.tildeAbbreviated($0)) })
            return lastError.map { "err " + $0 } ?? "ok"
        case "add":
            guard !rest.isEmpty else { return "err usage: chain add PATH" }
            guard FileManager.default.fileExists(atPath: expand(rest)) else {
                return "err no such file: \(rest)"
            }
            appendShader(rest)
            return lastError.map { "err " + $0 } ?? "ok"
        case "remove":
            guard let n = Int(rest), n >= 1, n <= chain.count else { return "err bad pass number" }
            removeEntry(at: n - 1)
            return "ok"
        case "toggle":
            guard let n = Int(rest), n >= 1, n <= chain.count else { return "err bad pass number" }
            toggleEntry(at: n - 1)
            return "ok"
        case "move":
            let ws = rest.split(separator: " ").compactMap { Int($0) }
            guard ws.count == 2, ws[0] >= 1, ws[0] <= chain.count,
                  ws[1] >= 1, ws[1] <= chain.count else { return "err usage: chain move FROM TO" }
            moveEntry(from: ws[0] - 1, to: ws[1] - 1)
            return "ok"
        case "clear":
            setChain([])
            return "ok"
        default:
            return "err unknown chain command: \(sub)"
        }
    }

    private func handleProfile(sub: String, rest: String) -> String {
        switch sub {
        case "", "list":
            let names = store.profileNames().map { n -> String in
                "\"\(n.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return "[" + names.joined(separator: ",") + "]"
        case "load":
            guard let name = ConfigStore.sanitize(profileName: rest) else { return "err bad name" }
            if let why = applyProfile(name) { return "err " + why }
            return lastError.map { "err " + $0 } ?? "ok"
        case "save":
            guard let name = ConfigStore.sanitize(profileName: rest) else { return "err bad name" }
            if let why = saveProfile(name) { return "err " + why }
            return "ok"
        case "delete":
            guard let name = ConfigStore.sanitize(profileName: rest) else { return "err bad name" }
            store.deleteProfile(name)
            return "ok"
        default:
            return "err unknown profile command: \(sub)"
        }
    }

    // MARK: Space switches

    private func watchSpaceChanges() {
        // Right after a switch, SCK hands back stale frames from the middle of the
        // animation. Drawing those leaves a ghost. `hide` covers it by hiding the window
        // for 0.15 s, which shows the unshaded screen for that long; `freeze` instead
        // takes no new frames and holds the last intact one. Which is less distracting
        // has to be judged by eye, so both stay, and the default is off.
        //
        // The observer is always installed. It has to be switchable from the menu, and
        // deciding whether to install it from the value at launch would mean a restart
        // after switching it on.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.runtime.spaceFix != "off" else { return }
                self.suppressFramesUntil = CACurrentMediaTime() + 0.15
                if self.runtime.spaceFix == "hide" {
                    for s in self.surfaces { s.window.alphaValue = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        for s in self.surfaces { s.window.alphaValue = 1 }
                    }
                }
            }
    }

    // MARK: Status item — the only way out

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◲"
        let mc = MenuController(app: self)
        item.menu = mc.menu
        menuController = mc
        statusItem = item
    }

    func refreshStatusItem() {
        // Changing the glyph is the only visible signal when capture never attached.
        // No window comes up, so nothing on screen changes.
        statusItem?.button?.title = captureProblem != nil ? "◲⚠" : (bypassed ? "◱" : "◲")
    }

    /// Lowers the overlay while a menu is open. Otherwise the menu is laid **beneath**
    /// the glass and cannot be seen — the full reason is in setBelowMenus in Overlay.swift.
    func setOverlayBelowMenus(_ below: Bool) {
        for s in surfaces { s.window.setBelowMenus(below) }
    }

    @objc func reload() { loadChain(initial: false) }

    @objc func toggleBypass() {
        bypassed.toggle()
        if bypassed {
            for s in surfaces { s.renderer.usePassthrough() }
            status = Str.status_bypassed
        } else {
            applyPassesToAll()
            status = activeEntries.isEmpty ? Str.status_noShader
                : activeEntries.map { ($0.path as NSString).lastPathComponent }
                               .joined(separator: " → ")
        }
        refreshStatusItem()
        nudge()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: CaptureDelegate

    func capture(_ capture: DisplayCapture, didOutput pixelBuffer: CVPixelBuffer) {
        // Drawn straight from the capture queue. A hop to the main queue adds exactly
        // that much latency, and in this window latency is a visible defect.
        if suppressFramesUntil > 0 {
            if CACurrentMediaTime() < suppressFramesUntil { return }
            suppressFramesUntil = 0
        }
        guard let surf = surfaces.first(where: { $0.displayID == capture.displayID })
        else { return }
        surf.renderer.render(pixelBuffer, pointer: surf.pointerInScreen,
                             clicks: clicks.snapshot(for: surf.displayID))

        frames += 1
        if !sawFrame {
            sawFrame = true
            DispatchQueue.main.async {
                self.captureWatchdog?.cancel()
                self.captureWatchdog = nil
                if self.captureProblem != nil {
                    self.captureProblem = nil
                    self.refreshStatusItem()
                }
            }
        }

        if flags.diag, frames % 20 == 0,
           let f = FeedbackProbe.magentaFraction(in: pixelBuffer) {
            probeSum += f; probeCount += 1
        }
        if !surf.isPresented {
            surf.isPresented = true
            let (w, h) = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
            DispatchQueue.main.async {
                surf.window.orderFrontRegardless()
                self.log(Str.log_firstFrame(surf.screen.localizedName, w, h))
            }
        }
    }

    func capture(_ capture: DisplayCapture, didFailWith error: Error) {
        DispatchQueue.main.async {
            self.log(Str.log_captureStalled(error.localizedDescription))
            // A window with no frames arriving is a black screen. Take it down too.
            for s in self.surfaces where s.displayID == capture.displayID {
                s.window.orderOut(nil)
                s.isPresented = false
            }
        }
    }

    func log(_ s: String) {
        FileHandle.standardError.write(("global-shader: " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - Start

let argv = Array(CommandLine.arguments.dropFirst())

// Language is settled before parsing, because the parser's own errors already use the
// table. ConfigStore.shared is first created here, and one of the values decided inside
// it must not freeze into a string — see Unwritable in Config.swift.
Lang.resolveEarly(argv: argv)

let opts = parse(argv)

if opts.flags.version {
    print("global-shader \(Build.version) (\(Build.number))")
    exit(0)
}
if opts.flags.help {
    print(Str.cli_usage)
    exit(0)
}

/// Send one line to the running instance, print the reply, and exit.
func talkAndExit(_ cmd: String) -> Never {
    guard let reply = Control.send(cmd) else {
        FileHandle.standardError.write((Str.cli_err_notRunning + "\n").data(using: .utf8)!)
        exit(1)
    }
    print(reply)
    exit(reply.hasPrefix("err") ? 1 : 0)
}

// Control commands do not bring up the app.
if let cmd = opts.flags.client { talkAndExit(cmd.joined(separator: " ")) }

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write((Str.cli_err_noMetal + "\n").data(using: .utf8)!)
    exit(1)
}

// --check goes as far as translation and pipeline creation, with no window and no
// capture. It runs without Screen Recording permission, so syntax can be checked from
// wherever shaders are edited — an editor, CI, a rice script — without touching the screen.
if opts.flags.check {
    guard !opts.flags.shaderPaths.isEmpty else {
        FileHandle.standardError.write((Str.cli_err_checkNeedsFile + "\n").data(using: .utf8)!)
        exit(2)
    }
    guard let renderer = Renderer(device: device) else {
        FileHandle.standardError.write((Str.cli_err_noRenderer + "\n").data(using: .utf8)!); exit(1)
    }
    var specs: [Renderer.PassSpec] = []
    var lines: [String] = []
    var anyMoving = false
    for (i, path) in opts.flags.shaderPaths.enumerated() {
        do {
            let r = try ShaderSource.translate(path: path, promoteKnobs: opts.runtime.knobs)
            if opts.flags.dumpMSL { print(r.msl) }
            specs.append(Renderer.PassSpec(msl: r.msl, knobCount: r.knobs.count))
            let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let conv = ShaderSource.convention(of: raw)
            // `!motion` is read here too, against the file's defaults. Values pushed over
            // the socket are not here, and what --check has to answer is "what happens if
            // I just apply this file", so the defaults are the right basis.
            if ShaderSource.needsContinuousRedraw(raw) {
                let gates = r.knobs.filter { $0.gatesMotion }
                if gates.isEmpty || gates.contains(where: { $0.defaultValue != 0 }) {
                    anyMoving = true
                }
            }
            let n = opts.flags.shaderPaths.count > 1 ? "\(i + 1). " : ""
            var line = n + Str.check_ok((path as NSString).lastPathComponent, "\(conv)")
            if let d = r.demoted { line += "\n" + Str.check_demoted(d) }
            if !r.knobs.isEmpty {
                line += "\n" + Str.check_knobs(r.knobs.count, r.knobs.map {
                    "\($0.name)=\($0.defaultValue) [\($0.min)..\($0.max)]"
                }.joined(separator: ", "))
            }
            lines.append(line)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    do { try renderer.setPasses(specs) } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
    lines.append(Str.check_redraw(anyMoving ? Str.check_redrawOn : Str.word_off))
    // Name the knobs that can switch it off. Without this, the answer to "why is it on"
    // is one mark buried somewhere in the file, which is an answer nobody finds.
    for (i, path) in opts.flags.shaderPaths.enumerated() {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              ShaderSource.needsContinuousRedraw(raw) else { continue }
        let gates = KnobParser.parse(raw).filter { $0.gatesMotion && $0.defaultValue != 0 }
        guard !gates.isEmpty else { continue }
        let n = opts.flags.shaderPaths.count > 1 ? "\(i + 1). " : ""
        lines.append(Str.check_motionGates(n, gates.map(\.name).joined(separator: " ")))
    }
    FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(0)
}

// The instance lock comes before Metal, and a second run has one more use for it.
// Calling `global-shader crt.frag` while one is already running means "change it", not
// "bring up another" — that is where a script on Linux would talk to the compositor. So
// before refusing, we talk to it.
if !opts.flags.allowMultiple && !InstanceLock.acquire() {
    if let name = opts.flags.profile {
        talkAndExit("profile load " + name)
    }
    if !opts.flags.shaderPaths.isEmpty {
        talkAndExit("chain set " + opts.flags.shaderPaths.joined(separator: "\t"))
    }
    let pids = InstanceLock.otherPIDs().map(String.init).joined(separator: " ")
    let where_ = pids.isEmpty ? "" : Str.cli_alreadyRunning_pids(pids)
    FileHandle.standardError.write(
        (Str.cli_alreadyRunning(where_) + "\n").data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
// .accessory: no Dock icon, no app switcher. Only the status item.
app.setActivationPolicy(.accessory)
let delegate = App(options: opts, device: device)
app.delegate = delegate

// So Ctrl-C works when launched from a terminal. Dying in the default handler can leave
// the windows up, so it is routed through NSApp.terminate. The sources have to be held
// or they are released immediately and never fire.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { NSApp.terminate(nil) }
    src.resume()
    signalSources.append(src)
}

app.run()
