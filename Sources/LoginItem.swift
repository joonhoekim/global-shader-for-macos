import Foundation

// Coming up on its own at login.
//
// ── Why not SMAppService ─────────────────────────────────────────────────
// It is the standard login-item API on macOS 13+, and neither half of it fits here.
//
//   1. It carries no arguments. SMAppService.mainApp just launches the app, leaving
//      nowhere to hang something like "start with this profile" later.
//   2. The app rewrites its own registration state. In an environment that wants that
//      state held declaratively (Nix launchd.user.agents, for instance) there are then
//      two truths, and when they diverge you get "I definitely turned it off and it
//      still comes up at login".
//
// So a LaunchAgent, written directly. That makes it **the same object** a configuration
// manager would place, so moving to a declarative setup later does not conflict with
// what the app was doing.
//
// ── Why the executable inside the bundle is called directly ──────────────
// `open -a` launches the app and **exits immediately.** launchd reads that as "the job
// finished", which does not fit RunAtLoad. And this app is ad-hoc signed (-s -), so
// TCC's Screen Recording grant hangs on the cdhash either way.
enum LoginItem {

    static var label: String { Ident.agentLabel }

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The real path of the binary running right now.
    ///
    /// build/global-shader is a symlink into the bundle, so without resolving it the
    /// agent would call a broken link once the repo moves.
    static var executablePath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    // MARK: State

    enum State {
        case off
        case on
        /// Somebody else is already doing the same job. Adding one of our own makes two
        /// instances, and in this app that is feedback (see Instance.swift).
        case managedElsewhere(label: String, byNix: Bool)

        var isOn: Bool {
            switch self {
            case .off: return false
            case .on, .managedElsewhere: return true
            }
        }
    }

    static func state() -> State {
        if let other = foreignAgent() { return other }
        return FileManager.default.fileExists(atPath: plistURL.path) ? .on : .off
    }

    /// Finds an agent in ~/Library/LaunchAgents that calls this binary but is **not ours**.
    ///
    /// nix-darwin installs launchd.user.agents.<name> under the label `org.nixos.<name>`,
    /// which can never collide with ours. Flipping the toggle on without seeing it means
    /// two launches at login, and two instances capture each other's overlay — the lock
    /// refuses the second, so the screen does not fall apart, but it becomes "sometimes
    /// it does not come up".
    private static func foreignAgent() -> State? {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        let me = executablePath
        for url in items where url.pathExtension == "plist" {
            guard url.lastPathComponent != plistURL.lastPathComponent,
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any] else { continue }

            var argv = (plist["ProgramArguments"] as? [String]) ?? []
            if let p = plist["Program"] as? String { argv.append(p) }
            // Exactly the same path, or at least calling this app's executable, is us.
            guard argv.contains(where: {
                $0 == me || $0.hasSuffix("/MacOS/global-shader")
            }) else { continue }

            let lbl = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            // A symlink into the store means Nix installed it. That is how nix-darwin
            // puts things in ~/Library/LaunchAgents.
            let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let byNix = dest?.hasPrefix("/nix/store/") == true || lbl.hasPrefix("org.nixos.")
            return .managedElsewhere(label: lbl, byNix: byNix)
        }
        return nil
    }

    // MARK: Turning it on and off

    /// nil on success, otherwise a reason a person can read.
    static func setEnabled(_ on: Bool) -> String? {
        if case .managedElsewhere(let lbl, let byNix) = state() {
            return byNix
                ? Str.login_err_managedByNix(lbl)
                : Str.login_err_managedElsewhere(lbl)
        }
        return on ? enable() : disable()
    }

    private static func enable() -> String? {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Rewritten with the current path every time it is switched on, so that switching
        // it off and on again is the fix after moving the app.
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // What a person quit from the menu stays quit. KeepAlive would let the overlay
            // come back on its own, which is alarming for something that covers the whole
            // screen.
            "KeepAlive": false,
            // Somewhere for diagnostics to land. A quiet failure at login has no other
            // symptom — the screen simply looks normal, with no way to tell what went wrong.
            "StandardOutPath": "/tmp/global-shader.log",
            "StandardErrorPath": "/tmp/global-shader.log",
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return Str.login_err_writeAgent(error.localizedDescription)
        }

        // Take down whatever is up and put it back. Bootstrapping with a changed path is
        // refused with "already loaded".
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let r = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        // This very process is already running, so bootstrap's RunAtLoad tries to start a
        // second one and is stopped by the instance lock. That is expected and does not
        // count as failure — the file is in place, so it comes up at the next login.
        if r.status != 0 && !FileManager.default.fileExists(atPath: plistURL.path) {
            return Str.login_err_bootstrap(r.output)
        }
        return nil
    }

    private static func disable() -> String? {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        do { try FileManager.default.removeItem(at: plistURL) }
        catch {
            // If it was never there, the goal is already met.
            if FileManager.default.fileExists(atPath: plistURL.path) {
                return Str.login_err_removeAgent(error.localizedDescription)
            }
        }
        return nil
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
