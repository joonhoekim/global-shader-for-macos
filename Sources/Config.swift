import Foundation

// Settings and profiles — everything the app remembers across a restart.
//
//   $XDG_CONFIG_HOME/global-shader/        (default ~/.config/global-shader)
//     config.json          the chain in force · shader folders · run options · login item
//     profiles/<name>.json  one chain, named and frozen
//     shaders/             the default shader folder (created even when empty)
//
// ── Why not ~/Library/Preferences (UserDefaults) ─────────────────────────
// This app assumes it will live in an environment that **manages configuration
// declaratively** (Nix home-manager, chezmoi, a dotfiles repo). Those environments share
// one constraint: a config file symlinked out of a store or a repo makes its target
// read-only, so values a person edits by hand are seeded — copied only when absent —
// leaving a genuinely writable file behind.
//
// UserDefaults cannot join that layer. It is a binary plist, so git cannot diff it, and
// cfprefsd holds a cache, so when a value written from outside takes effect is unclear.
// A single JSON file, by contrast, can be seeded by a configuration manager, edited by a
// person, and committed.
//
// So it is written as sorted, pretty JSON. A one-value change has to be a one-line diff
// before anyone wants to keep it in a repo.

// MARK: - What it holds

/// One slot of the chain: one shader file and the values a person set for it.
struct ChainEntry: Codable, Equatable {
    var path: String
    var enabled: Bool = true
    /// Knob name → value. Only what differs from the shader file's default.
    var knobs: [String: Float] = [:]

    enum CodingKeys: String, CodingKey { case path, enabled, knobs }

    init(path: String, enabled: Bool = true, knobs: [String: Float] = [:]) {
        self.path = path; self.enabled = enabled; self.knobs = knobs
    }

    // So a hand-written profile can leave out enabled and knobs. The shortest way to
    // write a chain has to be `{"path": "..."}` for it to be worth writing from nix.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        knobs = try c.decodeIfPresent([String: Float].self, forKey: .knobs) ?? [:]
    }
}

/// Values attached to **how** it is applied, not to the shader. Frozen into profiles as
/// well — a heavy shader wants a lower scale, and that judgement differs per shader.
struct RuntimeOptions: Codable, Equatable {
    var fps: Int? = nil            // nil means the display's refresh rate
    var scale: Double = 1.0
    var redraw: String = "auto"    // auto | always | never
    var spaceFix: String = "off"   // off | freeze | hide
    var knobs: Bool = true
    var capturable: Bool = false
    var hotReload: Bool = true

    enum CodingKeys: String, CodingKey {
        case fps, scale, redraw, spaceFix, knobs, capturable, hotReload
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = RuntimeOptions()
        fps        = try c.decodeIfPresent(Int.self,    forKey: .fps)
        scale      = try c.decodeIfPresent(Double.self, forKey: .scale)      ?? z.scale
        redraw     = try c.decodeIfPresent(String.self, forKey: .redraw)     ?? z.redraw
        spaceFix   = try c.decodeIfPresent(String.self, forKey: .spaceFix)   ?? z.spaceFix
        knobs      = try c.decodeIfPresent(Bool.self,   forKey: .knobs)      ?? z.knobs
        capturable = try c.decodeIfPresent(Bool.self,   forKey: .capturable) ?? z.capturable
        hotReload  = try c.decodeIfPresent(Bool.self,   forKey: .hotReload)  ?? z.hotReload
        scale = Swift.min(Swift.max(scale, 0.25), 1.0)
    }
}

/// One chain, saved under a name.
struct Profile: Codable {
    var chain: [ChainEntry] = []
    /// Absent leaves the current run options alone. It lets a hand-written profile name
    /// only a chain, and it also means "a profile that does not touch the scale".
    var options: RuntimeOptions? = nil
}

struct Config: Codable {
    var shaderPaths: [String] = []
    var chain: [ChainEntry] = []
    /// The last profile applied. Used only to put a checkmark in the menu — the truth is
    /// always chain, and this is a label stuck on top of it.
    var profile: String? = nil
    var options = RuntimeOptions()
    var launchAtLogin = false
    /// The language picked from the menu. nil follows the system.
    ///
    /// Here rather than in RuntimeOptions for the reason set out at the top of main.swift:
    /// a language is taste, not a run option you are measuring once. It belongs with the
    /// shader paths, not with `--scale`.
    var lang: String? = nil

    enum CodingKeys: String, CodingKey {
        case shaderPaths, chain, profile, options, launchAtLogin, lang
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        shaderPaths   = try c.decodeIfPresent([String].self,     forKey: .shaderPaths)   ?? []
        chain         = try c.decodeIfPresent([ChainEntry].self, forKey: .chain)         ?? []
        profile       = try c.decodeIfPresent(String.self,       forKey: .profile)
        options       = try c.decodeIfPresent(RuntimeOptions.self, forKey: .options)     ?? RuntimeOptions()
        launchAtLogin = try c.decodeIfPresent(Bool.self,         forKey: .launchAtLogin) ?? false
        lang          = try c.decodeIfPresent(String.self,       forKey: .lang)
    }
}

// MARK: - Reading and writing

final class ConfigStore {

    static let shared = ConfigStore()

    /// Free to edit from outside. Calling save() afterwards is the caller's job — an
    /// automatic didSet here would rewrite the file three or four times per chain edit.
    var config = Config()

    /// Why the settings cannot be written. Held as a case rather than a string because
    /// this value is decided inside ConfigStore.init, which runs before Lang.resolve.
    /// Frozen as a string, the configured language would fail to reach this one line.
    enum Unwritable {
        case nixSymlink
        case other(String)

        var message: String {
            switch self {
            case .nixSymlink:    return Str.config_err_nixSymlink
            case .other(let d):  return Str.config_err_writeFailed(d)
            }
        }
    }

    private(set) var readOnly: Unwritable?

    /// Why the settings cannot be written. nil means they can.
    ///
    /// Not dying here matters. Under nix the config file can end up a read-only symlink
    /// into the store (home.file / xdg.configFile), and the app has to keep running —
    /// values changed from the menu live in memory for this run and simply do not survive
    /// to the next. The menu says so.
    var readOnlyReason: String? { readOnly?.message }

    let dir: URL
    var configFile: URL { dir.appendingPathComponent("config.json") }
    var profileDir: URL { dir.appendingPathComponent("profiles") }
    var defaultShaderDir: URL { dir.appendingPathComponent("shaders") }

    private var saveTimer: DispatchSourceTimer?

    private init() {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        dir = base.appendingPathComponent("global-shader")
        load()
    }

    // MARK: Loading

    private func load() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultShaderDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: configFile),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        } else {
            config = Config()
            config.shaderPaths = ConfigStore.defaultShaderPaths()
            // Written straight away on first run. The file has to exist before anyone
            // opens and edits it — the point is not making people look up "where is the
            // config file" in the documentation.
            save(immediately: true)
        }
        if config.shaderPaths.isEmpty { config.shaderPaths = ConfigStore.defaultShaderPaths() }
    }

    /// Shader folders seeded on first run.
    ///
    /// `~/.config/hypr/shaders` being here is no accident. This repo's goal is running
    /// Hyprland `.frag` files **unchanged** (README), so looking from the start at where
    /// shaders already sit on the Linux side is the right move. Absent, it just does not
    /// appear in the list; no harm done.
    private static func defaultShaderPaths() -> [String] {
        var out = ["~/.config/global-shader/shaders", "~/.config/hypr/shaders"]
        if let repo = repoShaderDir() { out.append(tildeAbbreviated(repo)) }
        return out
    }

    /// `<repo>/shaders`, for running a build from inside a checkout.
    ///
    /// Without this, someone who just built it sees an empty shader list while the
    /// shaders sit in the repo they cloned a minute ago.
    ///
    /// Found by walking up from the executable. In a bundle that is
    /// `<repo>/build/GlobalShader.app/Contents/MacOS/global-shader`, five levels; running
    /// the bare binary is shallower. Rather than counting levels, it checks for **the
    /// repo's markers** — `shaders/` and `build.sh` side by side. Picking on the name
    /// `shaders` alone could mistake somebody else's folder for the repo.
    private static func repoShaderDir() -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: LoginItem.executablePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let shaders = dir.appendingPathComponent("shaders")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: shaders.path, isDirectory: &isDir), isDir.boolValue,
               fm.fileExists(atPath: dir.appendingPathComponent("build.sh").path) {
                return shaders.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: Saving

    /// Dragging a knob can call this dozens of times a second, so writes are coalesced.
    /// Not to spare the disk, but because a file churning while a slider moves makes an
    /// editor or a watcher looking at it noisy.
    func scheduleSave() {
        saveTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0)
        t.setEventHandler { [weak self] in self?.save(immediately: true) }
        t.resume()
        saveTimer = t
    }

    func save(immediately: Bool = false) {
        if !immediately { scheduleSave(); return }
        saveTimer?.cancel(); saveTimer = nil

        let enc = JSONEncoder()
        // sortedKeys is what makes the same settings land as the same bytes. This file is
        // meant to be committed, so a one-value change has to be a one-line diff.
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(config) else { return }
        do {
            try data.write(to: configFile, options: .atomic)
            readOnly = nil
        } catch {
            readOnly = describeUnwritable(configFile, error)
        }
    }

    private func describeUnwritable(_ url: URL, _ error: Error) -> Unwritable {
        // A store symlink is common enough to name outright. Saying only "permission
        // denied" leaves you to go find out why.
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path),
           dest.hasPrefix("/nix/store/") {
            return .nixSymlink
        }
        return .other(error.localizedDescription)
    }

    // MARK: Profiles

    /// The name becomes a file name. Blocking path separators and a leading dot is not
    /// security but accident prevention — so a name like `..` cannot overwrite something else.
    static func sanitize(profileName n: String) -> String? {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("."), !t.contains("/"), t != "..",
              t.count <= 64 else { return nil }
        return t
    }

    func profileNames() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: profileDir.path)) ?? []
        return items.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func profileURL(_ name: String) -> URL {
        profileDir.appendingPathComponent(name + ".json")
    }

    func loadProfile(_ name: String) -> Profile? {
        guard let data = try? Data(contentsOf: profileURL(name)) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    @discardableResult
    func saveProfile(_ name: String, _ p: Profile) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(p) else { return Str.config_err_encodeFailed }
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        do { try data.write(to: profileURL(name), options: .atomic); return nil }
        catch { return describeUnwritable(profileURL(name), error).message }
    }

    func deleteProfile(_ name: String) {
        try? FileManager.default.removeItem(at: profileURL(name))
    }

    // MARK: Shader library

    struct LibraryDir {
        let path: String        // as written, for people to read (~ kept)
        let expanded: String
        let files: [String]     // **everything** under this folder, absolute. For counting.
        let tree: LibraryGroup  // the folder shape as is. The menu builds submenus from this.
    }

    /// One level. The root's `name` is the empty string.
    struct LibraryGroup {
        let name: String
        let files: [String]         // what sits directly at this level
        let groups: [LibraryGroup]  // subfolders
        /// A branch with no shader anywhere below it. Dropped from the menu wholesale —
        /// a list of empty folder names only tells you they are empty after you click.
        var isEmpty: Bool { files.isEmpty && groups.allSatisfy { $0.isEmpty } }
    }

    /// Walks the configured folders. **Subfolders included.**
    ///
    /// A dozen shaders in one flat list means reading every name to find out what each
    /// one is, and that is a quiz, not a list. When the folder is the family name, the
    /// names do not have to be read at all.
    ///
    /// Depth is capped because a menu inside a menu gets hard to follow with a mouse past
    /// two levels. Levels beyond the cap are not ignored but **flattened** into the level
    /// above (`flatten` below) — otherwise files vanish quietly and people go hunting for
    /// a shader that is not in the list.
    func library() -> [LibraryDir] {
        var seen = Set<String>()
        var out: [LibraryDir] = []
        for raw in config.shaderPaths {
            let expanded = (raw as NSString).expandingTildeInPath
            // The same folder listed twice counts once. A default and a hand-added path
            // overlapping is common.
            guard seen.insert(expanded).inserted else { continue }
            var visited = Set<String>()
            let tree = ConfigStore.scan(expanded, name: "", depth: 0, visited: &visited)
            out.append(LibraryDir(path: raw, expanded: expanded,
                                  files: ConfigStore.flatFiles(tree), tree: tree))
        }
        return out
    }

    private static let shaderExts: Set<String> = ["frag", "glsl", "fs", "fsh", "fragment"]

    /// How deep a menu is worth following. Anything below this is flattened into this level.
    private static let maxDepth = 2

    private static func scan(_ dir: String, name: String, depth: Int,
                             visited: inout Set<String>) -> LibraryGroup {
        // A symlink pointing back up would loop forever. Real paths, visited once.
        let real = (dir as NSString).resolvingSymlinksInPath
        guard visited.insert(real).inserted else {
            return LibraryGroup(name: name, files: [], groups: [])
        }

        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }          // .DS_Store and other hidden things
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var files: [String] = []
        var groups: [LibraryGroup] = []
        for item in items {
            let full = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let sub = scan(full, name: item, depth: depth + 1, visited: &visited)
                if sub.isEmpty { continue }
                // Too deep, so pull it up to this level. The folder name is lost but the
                // files do not vanish from the list — the lesser of the two evils.
                if depth + 1 > maxDepth {
                    files.append(contentsOf: flatFiles(sub))
                } else {
                    groups.append(sub)
                }
            } else if shaderExts.contains((item as NSString).pathExtension.lowercased()) {
                files.append(full)
            }
        }
        return LibraryGroup(name: name, files: files, groups: groups)
    }

    private static func flatFiles(_ g: LibraryGroup) -> [String] {
        g.files + g.groups.flatMap { flatFiles($0) }
    }

    func addShaderPath(_ path: String) {
        let tilde = ConfigStore.tildeAbbreviated(path)
        guard !config.shaderPaths.contains(tilde),
              !config.shaderPaths.contains(path) else { return }
        config.shaderPaths.append(tilde)
        save(immediately: true)
    }

    func removeShaderPath(_ path: String) {
        config.shaderPaths.removeAll { $0 == path }
        save(immediately: true)
    }

    /// Abbreviated to `~` when under home. It survives a change of machine, and above all
    /// it keeps the user name out of a commit.
    static func tildeAbbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
