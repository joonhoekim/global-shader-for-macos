import AppKit

// Everything goes into one menu bar item.
//
// There is no separate settings window because this app is LSUIElement. Putting up a
// window means activating an accessory app, which takes focus from whatever you were
// using — a tool that lays glass over the screen interrupting your work to change one
// scale value does not add up. A menu moves no focus, and a real window comes up only
// briefly where one is genuinely needed, like choosing a folder.
//
// ── Rebuilt on every open ────────────────────────────────────────────────
// Rather than holding items and patching them as state changes, menuNeedsUpdate rebuilds
// the whole thing. A changed chain changes the item count, knobs differ per shader, and
// profiles can grow from outside (from nix). Code reconciling that incrementally will
// drift on some path, and a menu that has drifted tells lies. The cost of building one
// menu is nothing next to how often a person opens it.

/// A menu item that carries its closure directly.
///
/// Putting a number in the tag and switching on it in one selector goes quietly wrong the
/// moment a number and its meaning drift apart, and there are this many items.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off,
         key: String = "", tip: String? = nil, indent: Int = 0,
         _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.target = self
        self.isEnabled = enabled
        self.state = state
        self.toolTip = tip
        self.indentationLevel = indent
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { run() }
}

/// A line that only explains. Not clickable.
func infoItem(_ title: String, tip: String? = nil, indent: Int = 0) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    i.toolTip = tip
    i.indentationLevel = indent
    return i
}

// MARK: - Sliders in the menu

/// One row for dragging a single knob right in the menu.
///
/// The socket and the CLI can do it too, but setting a value **while watching it** needs
/// the hand next to the screen. A shader value is not chosen by knowing the number; it is
/// stopped at by looking, and the shorter round trip wins.
final class KnobSliderView: NSView {

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Float) -> Void

    init(knob: Knob, value: Float, width: CGFloat = 268,
         onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))

        let name = NSTextField(labelWithString: knob.name)
        name.font = .menuFont(ofSize: NSFont.systemFontSize(for: .small))
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 21, y: 17, width: width - 90, height: 14)

        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: width - 68, y: 17, width: 54, height: 14)

        slider.minValue = Double(knob.min)
        slider.maxValue = Double(knob.max)
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(moved)
        // With a step declared, it lands only on those marks. A shader writing
        // `@0..1:0.01` is its author judging that finer than this is not visible.
        if let step = knob.step, step > 0 {
            let n = Int(((knob.max - knob.min) / step).rounded()) + 1
            if n > 1 && n <= 2000 {
                slider.numberOfTickMarks = n
                slider.allowsTickMarkValuesOnly = true
                slider.tickMarkPosition = .below
            }
        }
        slider.frame = NSRect(x: 20, y: 0, width: width - 36, height: 18)

        addSubview(name)
        addSubview(valueLabel)
        addSubview(slider)
        updateLabel()
        // The comment the shader wrote above the value doubles as the description. This
        // repo's shaders already say why each value is what it is.
        toolTip = knob.doc.isEmpty ? nil : knob.doc
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func moved() {
        updateLabel()
        onChange(Float(slider.doubleValue))
    }

    private func updateLabel() {
        let v = slider.doubleValue
        // Widen the digits when the range is narrow. A 0..0.3 knob shown to two decimals
        // has stretches where moving the slider does not change the number.
        let span = slider.maxValue - slider.minValue
        let digits = span >= 100 ? 0 : (span >= 10 ? 1 : (span >= 1 ? 2 : 3))
        valueLabel.stringValue = String(format: "%.\(digits)f", v)
    }
}

// MARK: - Dialogs

enum Dialogs {

    /// Put it above the overlay.
    ///
    /// NSAlert is modalPanel (8) and NSOpenPanel is near it, while the overlay is
    /// CGShieldingWindowLevel (2.1 billion). Left alone it is laid under the glass and
    /// **waits for input without being visible** — the worst possible shape, since the
    /// app looks frozen.
    private static func raise(_ w: NSWindow?) {
        w?.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    }

    static func askText(title: String, message: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: Str.dlg_save)
        a.addButton(withTitle: Str.dlg_cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.window.initialFirstResponder = field
        raise(a.window)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func confirm(title: String, message: String, destructive: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: destructive)
        a.addButton(withTitle: Str.dlg_cancel)
        a.buttons.first?.hasDestructiveAction = true
        raise(a.window)
        return a.runModal() == .alertFirstButtonReturn
    }

    static func tell(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: Str.dlg_ok)
        raise(a.window)
        _ = a.runModal()
    }

    static func chooseFolder(title: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.message = title
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        raise(p)
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseShaderFile() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.message = Str.dlg_chooseShaderFile
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        raise(p)
        return p.runModal() == .OK ? p.url : nil
    }
}

// MARK: - The menu

final class MenuController: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    private unowned let app: App
    private var store: ConfigStore { app.store }

    init(app: App) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // The overlay is lowered only while the menu is open. Without this the menu is laid
    // under the glass and not one pixel of it is visible (see Overlay.swift).
    func menuWillOpen(_ menu: NSMenu) { app.setOverlayBelowMenus(true) }
    func menuDidClose(_ menu: NSMenu) { app.setOverlayBelowMenus(false) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(into: menu)
    }

    /// Putting up a dialog has to happen **after** the menu closes. The menu is running
    /// its own event loop, and opening a modal inside it makes the two overlap.
    private func afterClose(_ run: @escaping () -> Void) {
        DispatchQueue.main.async(execute: run)
    }

    // MARK: Building

    private func build(into m: NSMenu) {
        let entries = app.chain
        let active = app.activeEntries

        // ── Status ──
        let title = app.bypassed
                  ? Str.menu_title_off(active.isEmpty ? Str.menu_title_noShader
                                                      : Str.menu_title_passCount(active.count))
                  : active.isEmpty ? Str.menu_title_passthrough
                  : active.map { ($0.path as NSString).lastPathComponent }.joined(separator: " → ")
        m.addItem(infoItem(title, tip: app.status))

        // Capture not attaching comes first. In that state no window comes up at all, so
        // the screen holds no clue and this is the only place a person can see it.
        if let p = app.captureProblem {
            m.addItem(infoItem("⚠︎ " + p))
            m.addItem(ActionItem(Str.menu_openScreenSettings, indent: 1) { [weak self] in
                self?.app.openScreenRecordingSettings()
            })
            m.addItem(infoItem(Str.menu_mayBeDenied,
                               tip: Str.menu_mayBeDenied_tip(Ident.bundleID), indent: 1))
            m.addItem(ActionItem(Str.menu_copyFix, indent: 1) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("tccutil reset ScreenCapture \(Ident.bundleID)",
                             forType: .string)
            })
            m.addItem(.separator())
        }

        if let e = app.lastError {
            let first = e.split(separator: "\n").first.map(String.init) ?? e
            m.addItem(infoItem("⚠︎ " + first, tip: e))
        }
        if let ro = store.readOnlyReason {
            m.addItem(infoItem("⚠︎ " + ro, tip: store.configFile.path))
        }
        m.addItem(.separator())

        // ── Chain ──
        let chainItem = NSMenuItem(title: Str.menu_chain, action: nil, keyEquivalent: "")
        chainItem.submenu = buildChain(entries)
        m.addItem(chainItem)

        // ── Knobs ──
        let knobItem = NSMenuItem(title: Str.menu_knobs, action: nil, keyEquivalent: "")
        let knobMenu = buildKnobs()
        knobItem.submenu = knobMenu
        knobItem.isEnabled = knobMenu.numberOfItems > 0
        m.addItem(knobItem)

        // ── Profiles ──
        let profItem = NSMenuItem(title: Str.menu_profiles, action: nil, keyEquivalent: "")
        profItem.submenu = buildProfiles()
        m.addItem(profItem)

        // ── Settings ──
        let setItem = NSMenuItem(title: Str.menu_settings, action: nil, keyEquivalent: "")
        setItem.submenu = buildSettings()
        m.addItem(setItem)

        m.addItem(.separator())
        m.addItem(ActionItem(Str.menu_reload, key: "r") { [weak self] in self?.app.reload() })
        m.addItem(ActionItem(app.bypassed ? Str.menu_shaderOn : Str.menu_shaderOff, key: "t") {
            [weak self] in self?.app.toggleBypass()
        })
        m.addItem(.separator())
        m.addItem(ActionItem(Str.menu_quit, key: "q") { NSApp.terminate(nil) })
    }

    // MARK: Chain

    private func buildChain(_ entries: [ChainEntry]) -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false

        if entries.isEmpty {
            s.addItem(infoItem(Str.menu_empty))
        }
        for (i, e) in entries.enumerated() {
            let name = (e.path as NSString).lastPathComponent
            let item = NSMenuItem(title: "\(i + 1). \(name)", action: nil, keyEquivalent: "")
            item.state = e.enabled ? .on : .off
            item.toolTip = e.path
            item.submenu = buildEntry(i, e, count: entries.count)
            s.addItem(item)
        }

        s.addItem(.separator())
        let add = NSMenuItem(title: Str.menu_addShader, action: nil, keyEquivalent: "")
        add.submenu = buildLibrary()
        s.addItem(add)
        if !entries.isEmpty {
            s.addItem(ActionItem(Str.menu_clearChain) { [weak self] in self?.app.setChain([]) })
        }
        return s
    }

    private func buildEntry(_ i: Int, _ e: ChainEntry, count: Int) -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        s.addItem(ActionItem(Str.menu_chain_moveUp, enabled: i > 0) { [weak self] in
            self?.app.moveEntry(from: i, to: i - 1)
        })
        s.addItem(ActionItem(Str.menu_chain_moveDown, enabled: i < count - 1) { [weak self] in
            self?.app.moveEntry(from: i, to: i + 1)
        })
        s.addItem(.separator())
        s.addItem(ActionItem(e.enabled ? Str.menu_chain_disable : Str.menu_chain_enable) { [weak self] in
            self?.app.toggleEntry(at: i)
        })
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_revealInFinder) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.selectFile(self.app.expand(e.path),
                                          inFileViewerRootedAtPath: "")
        })
        s.addItem(ActionItem(Str.menu_chain_remove) { [weak self] in self?.app.removeEntry(at: i) })
        return s
    }

    /// The shader files in the configured folders.
    private func buildLibrary() -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        let dirs = store.library().filter { !$0.files.isEmpty }
        let inChain = Set(app.chain.map { app.expand($0.path) })

        if dirs.isEmpty {
            s.addItem(infoItem(Str.menu_shaderDirEmpty))
            s.addItem(infoItem(Str.menu_shaderDirHint))
        }
        // With only one folder, one level is folded away — no reason to make anyone click
        // through a folder name for nothing.
        let flat = dirs.count == 1
        for d in dirs {
            let target: NSMenu
            if flat {
                target = s
            } else {
                let sub = NSMenu()
                sub.autoenablesItems = false
                let host = NSMenuItem(title: shortDir(d.path), action: nil, keyEquivalent: "")
                host.toolTip = d.expanded
                host.submenu = sub
                s.addItem(host)
                target = sub
            }
            fillLibrary(target, d.tree, inChain: inChain)
        }
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_chooseOtherFile) { [weak self] in
            self?.afterClose {
                guard let url = Dialogs.chooseShaderFile() else { return }
                self?.app.appendShader(url.path)
            }
        })
        return s
    }

    /// One folder level as one menu level. Subfolders first, then this level's files.
    ///
    /// That order is because the folder is the family name — you look at the families and
    /// then go into one, which is the order a list is read; files on top push the families
    /// below the fold. A separator is drawn only when there are both.
    private func fillLibrary(_ menu: NSMenu, _ g: ConfigStore.LibraryGroup,
                             inChain: Set<String>) {
        for sub in g.groups where !sub.isEmpty {
            let m = NSMenu()
            m.autoenablesItems = false
            fillLibrary(m, sub, inChain: inChain)
            let host = NSMenuItem(title: sub.name, action: nil, keyEquivalent: "")
            host.submenu = m
            menu.addItem(host)
        }
        if !g.groups.isEmpty && !g.files.isEmpty { menu.addItem(.separator()) }
        for f in g.files {
            let name = (f as NSString).lastPathComponent
            menu.addItem(ActionItem(name, state: inChain.contains(f) ? .on : .off,
                                    tip: f) { [weak self] in
                self?.app.appendShader(f)
            })
        }
    }

    private func shortDir(_ p: String) -> String {
        let n = (p as NSString).lastPathComponent
        return n.isEmpty ? p : n
    }

    // MARK: Knobs

    private func buildKnobs() -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        let passes = app.knobs.snapshot()

        if !app.runtime.knobs {
            s.addItem(infoItem(Str.menu_knobsDisabled))
            s.addItem(ActionItem(Str.menu_turnOn) { [weak self] in
                guard let self else { return }
                var r = self.app.runtime; r.knobs = true
                self.app.applyRuntime(r)
            })
            return s
        }
        if passes.isEmpty {
            s.addItem(infoItem(Str.menu_noShaders))
            return s
        }

        // A long chain cannot lay its sliders out on one level. crt.frag alone has 30
        // knobs and ocean.frag after it has 15, so even two slots overlapping makes the
        // menu longer than the screen and scroll arrows appear — at which point it can no
        // longer be scanned. With more than one slot, each shader is folded away.
        let many = passes.count > 1
        for (i, p) in passes.enumerated() {
            let target: NSMenu
            if many {
                let sub = NSMenu()
                sub.autoenablesItems = false
                let host = NSMenuItem(title: "\(i + 1). \(p.shaderName)", action: nil,
                                      keyEquivalent: "")
                host.toolTip = p.path
                host.submenu = sub
                s.addItem(host)
                target = sub
            } else {
                target = s
            }

            if let d = p.demoted {
                // Say why there are no sliders. Showing nothing is indistinguishable from
                // a shader that has no knobs.
                target.addItem(infoItem(Str.menu_knobsFolded, tip: d))
                continue
            }
            if p.knobs.isEmpty {
                target.addItem(infoItem(Str.menu_noRangedDefines))
                continue
            }
            for k in p.knobs {
                let item = NSMenuItem()
                item.view = KnobSliderView(knob: k, value: p.values[k.name] ?? k.defaultValue) {
                    [weak self] v in
                    guard let self else { return }
                    _ = self.app.knobs.set("\(i + 1).\(k.name)", v)
                    self.app.knobsChanged()
                }
                target.addItem(item)
            }
            target.addItem(.separator())
            target.addItem(ActionItem(Str.menu_resetPass) { [weak self] in
                guard let self else { return }
                _ = self.app.knobs.reset("\(i + 1).")
                self.app.knobsChanged()
            })
        }
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_resetAll) { [weak self] in
            guard let self else { return }
            _ = self.app.knobs.reset(nil)
            self.app.knobsChanged()
        })
        return s
    }

    // MARK: Profiles

    private func buildProfiles() -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        let names = store.profileNames()
        let current = store.config.profile

        if names.isEmpty {
            s.addItem(infoItem(Str.menu_noProfiles))
        }
        for n in names {
            s.addItem(ActionItem(n, state: n == current ? .on : .off) { [weak self] in
                guard let self else { return }
                if let why = self.app.applyProfile(n) {
                    self.afterClose { Dialogs.tell(Str.dlg_profileApplyFailed, why) }
                }
            })
        }
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_saveProfileAs) { [weak self] in
            self?.afterClose { self?.saveProfileFlow() }
        })
        if let c = current, names.contains(c) {
            s.addItem(ActionItem(Str.menu_overwriteProfile(c)) { [weak self] in
                guard let self else { return }
                if let why = self.app.saveProfile(c) {
                    self.afterClose { Dialogs.tell(Str.dlg_profileSaveFailed, why) }
                }
            })
        }
        if !names.isEmpty {
            let del = NSMenuItem(title: Str.menu_deleteProfile, action: nil, keyEquivalent: "")
            let ds = NSMenu()
            ds.autoenablesItems = false
            for n in names {
                ds.addItem(ActionItem(n) { [weak self] in
                    self?.afterClose {
                        guard Dialogs.confirm(title: Str.dlg_deleteProfile_title(n),
                                              message: Str.dlg_deleteProfile_body,
                                              destructive: Str.dlg_delete) else { return }
                        self?.store.deleteProfile(n)
                    }
                })
            }
            del.submenu = ds
            s.addItem(del)
        }
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_openProfileFolder) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.profileDir)
        })
        return s
    }

    private func saveProfileFlow() {
        let suggested = store.config.profile
            ?? app.activeEntries.first.map {
                (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension
            } ?? Str.menu_newProfile
        guard let raw = Dialogs.askText(
            title: Str.dlg_saveProfile_title,
            message: Str.dlg_saveProfile_body,
            initial: suggested) else { return }
        guard let name = ConfigStore.sanitize(profileName: raw) else {
            Dialogs.tell(Str.dlg_badName_title, Str.dlg_badName_body)
            return
        }
        if store.profileNames().contains(name),
           !Dialogs.confirm(title: Str.dlg_exists_title(name),
                            message: Str.dlg_exists_body,
                            destructive: Str.dlg_overwrite) { return }
        if let why = app.saveProfile(name) { Dialogs.tell(Str.dlg_profileSaveFailed, why) }
    }

    // MARK: Settings

    private func buildSettings() -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        let r = app.runtime

        // Shader folders
        let dirs = NSMenuItem(title: Str.menu_shaderFolders, action: nil, keyEquivalent: "")
        dirs.submenu = buildShaderPaths()
        s.addItem(dirs)
        s.addItem(.separator())

        // Scale
        s.addItem(choice(
            title: Str.menu_scale,
            options: [(Str.menu_scale_one, 1.0), ("0.9", 0.9), ("0.8", 0.8),
                      ("0.7", 0.7), ("0.6", 0.6), ("0.5", 0.5)],
            current: r.scale,
            tip: Str.menu_scale_tip
        ) { [weak self] v in
            guard let self else { return }
            var n = self.app.runtime; n.scale = v; self.app.applyRuntime(n)
        })

        // Frame cap
        let fpsOptions: [(String, Int?)] = [(Str.menu_fps_native, nil), ("120", 120),
                                            ("60", 60), ("30", 30)]
        s.addItem(choice(
            title: Str.menu_fps,
            options: fpsOptions,
            current: r.fps,
            tip: Str.menu_fps_tip
        ) { [weak self] v in
            guard let self else { return }
            var n = self.app.runtime; n.fps = v; self.app.applyRuntime(n)
        })

        // Redraw
        s.addItem(choice(
            title: Str.menu_redraw,
            options: [(Str.menu_redraw_auto, "auto"), (Str.menu_redraw_always, "always"),
                      (Str.menu_redraw_never, "never")],
            current: r.redraw,
            tip: Str.menu_redraw_tip
        ) { [weak self] v in
            guard let self else { return }
            var n = self.app.runtime; n.redraw = v; self.app.applyRuntime(n)
        })

        // Space switches
        s.addItem(choice(
            title: Str.menu_spaceFix,
            options: [(Str.menu_spaceFix_off, "off"), (Str.menu_spaceFix_freeze, "freeze"),
                      (Str.menu_spaceFix_hide, "hide")],
            current: r.spaceFix,
            tip: Str.menu_spaceFix_tip
        ) { [weak self] v in
            guard let self else { return }
            var n = self.app.runtime; n.spaceFix = v; self.app.applyRuntime(n)
        })

        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_knobPromotion, state: r.knobs ? .on : .off,
                             tip: Str.menu_knobPromotion_tip) {
            [weak self] in
            guard let self else { return }
            var n = self.app.runtime; n.knobs.toggle(); self.app.applyRuntime(n)
        })
        s.addItem(ActionItem(Str.menu_hotReload, state: r.hotReload ? .on : .off,
                             tip: Str.menu_hotReload_tip) { [weak self] in
            guard let self else { return }
            var n = self.app.runtime; n.hotReload.toggle(); self.app.applyRuntime(n)
        })
        s.addItem(ActionItem(Str.menu_capturable, state: r.capturable ? .on : .off,
                             tip: Str.menu_capturable_tip) {
            [weak self] in
            guard let self else { return }
            var n = self.app.runtime; n.capturable.toggle(); self.app.applyRuntime(n)
        })

        // Language. This app also shows in System Settings → General → Language & Region
        // (CFBundleLocalizations in Info.plist), but few people know the way there.
        let langOptions: [(String, String?)] =
            [(Str.menu_language_system, nil)]
            + LangCode.allCases.map { (Lang.displayName($0), $0.rawValue) }
        s.addItem(choice(
            title: Str.menu_language,
            options: langOptions,
            current: store.config.lang,
            tip: Str.menu_language_tip
        ) { v in Lang.choose(v) })

        s.addItem(.separator())
        s.addItem(loginItem())
        s.addItem(ActionItem(Str.menu_showConfigFile) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.selectFile(self.store.configFile.path,
                                          inFileViewerRootedAtPath: "")
        })
        return s
    }

    private func buildShaderPaths() -> NSMenu {
        let s = NSMenu()
        s.autoenablesItems = false
        let dirs = store.library()
        for d in dirs {
            let exists = FileManager.default.fileExists(atPath: d.expanded)
            let count = d.files.count
            let label = exists ? Str.menu_dir_count(d.path, count) : Str.menu_dir_missing(d.path)
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.toolTip = d.expanded
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(ActionItem(Str.menu_openInFinder, enabled: exists) {
                NSWorkspace.shared.open(URL(fileURLWithPath: d.expanded))
            })
            sub.addItem(ActionItem(Str.menu_removeFromList) { [weak self] in
                self?.store.removeShaderPath(d.path)
            })
            item.submenu = sub
            s.addItem(item)
        }
        if dirs.isEmpty { s.addItem(infoItem(Str.menu_noFolders)) }
        s.addItem(.separator())
        s.addItem(ActionItem(Str.menu_addFolder) { [weak self] in
            self?.afterClose {
                guard let url = Dialogs.chooseFolder(title: Str.dlg_chooseShaderFolder) else { return }
                self?.store.addShaderPath(url.path)
            }
        })
        return s
    }

    private func loginItem() -> NSMenuItem {
        let state = LoginItem.state()
        switch state {
        case .managedElsewhere(let label, let byNix):
            // Do not pretend it can be switched on and off. Adding one without knowing
            // about an agent nix installed makes two try to come up at login, and the
            // second is stopped by the lock — which reads as "sometimes it does not start".
            let who = byNix ? Str.word_nix : label
            return infoItem(Str.menu_loginItem_managed(who),
                            tip: Str.menu_loginItem_managed_tip(label))
        case .on, .off:
            let on = state.isOn
            return ActionItem(Str.menu_loginItem, state: on ? .on : .off,
                              tip: LoginItem.plistURL.path) { [weak self] in
                if let why = LoginItem.setEnabled(!on) {
                    self?.afterClose { Dialogs.tell(Str.dlg_loginItemFailed, why) }
                    return
                }
                self?.store.config.launchAtLogin = !on
                self?.store.save(immediately: true)
            }
        }
    }

    /// A submenu for picking one value. The current one is checked.
    private func choice<T: Equatable>(title: String, options: [(String, T)], current: T,
                                      tip: String? = nil,
                                      _ pick: @escaping (T) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.toolTip = tip
        let s = NSMenu()
        s.autoenablesItems = false
        for (label, value) in options {
            s.addItem(ActionItem(label, state: value == current ? .on : .off) { pick(value) })
        }
        item.submenu = s
        return item
    }
}
