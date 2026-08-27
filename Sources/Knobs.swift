import Foundation

// Knobs a shader declares for itself.
//
// The convention is not this repo's invention. It is the notation used on the Linux
// (Hyprland) side for pushing shader values live, carried over as is, which is why the
// same `.frag` file runs on both. A comment of `@min..max` next to a value makes it a
// knob; without one it is not:
//
//   #define CURVE   0.10   // @0..0.3
//   #define BLOOM   0.32   // @0..1:0.01     (a step, optional)
//   #define BLOOM_TAPS 16                    ← no mark, so not a knob
//
// ── Why the file had to be rewritten under Hyprland ──────────────────────
// The uniforms a Hyprland screen shader receives are decided by the compositor, and
// ours cannot be added. So changing a value meant rewriting the #define and applying the
// shader again — a round trip that runs several times a second while a slider moves.
//
// **That constraint is Hyprland's, not macOS's.** Here we decide the uniform list. So a
// `@`-marked #define promoted to a uniform means no rewriting the file and no
// re-translating — push a value over the socket and the next frame has it. The shader
// file is not touched by a single character. On Linux it stays an ordinary #define.
//
// ── The price ────────────────────────────────────────────────────────────
// A constant turned uniform takes what the compiler used to fold and makes it a runtime
// value. So promotion happens only when --knobs is on. Measurements are in
// docs/performance.md.

struct Knob {
    let name: String
    let defaultValue: Float
    let min: Float
    let max: Float
    let step: Float?
    /// The block of comment directly above the #define. This repo's shaders already say
    /// why each value is what it is, so it doubles as the slider's description.
    let doc: String

    /// Whether `!motion` followed the `@range`. It is the shader declaring "with this
    /// value at 0, the motion this knob owns stops".
    ///
    /// The automatic redraw decision reads it — see KnobSet.motionGate().
    let gatesMotion: Bool

    /// One object, for the socket.
    ///
    /// With a chain, `name` alone cannot say which shader a value belongs to. So `id`
    /// ("2.CURVE"), `pass`, and `shader` are **added** — the original fields are left
    /// alone, so anything reading only name/value/min/max keeps working unchanged.
    func json(id: String, pass: Int, shader: String, value: Float) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
        }
        let stepJSON = step.map { String($0) } ?? "null"
        return """
        {"id":"\(esc(id))","pass":\(pass),"shader":"\(esc(shader))","value":\(value),\
        "name":"\(name)","default":\(defaultValue),"min":\(min),"max":\(max),\
        "step":\(stepJSON),"motion":\(gatesMotion),"doc":"\(esc(doc))"}
        """
    }
}

enum KnobParser {

    // Only scalar floats. Something like a vec3 TINT carries no `@`, and would not match
    // here even if it did — it does not fit in one uniform.
    //
    // The last group is whatever remains on the line after the `@range`. `!motion` is
    // searched for inside it rather than pinned to a position: this repo's shaders often
    // continue with prose after the range (`// @0..0.3 within the band …`), and requiring
    // the mark immediately after the range would silently stop matching the moment prose
    // is added. Not matching leaves redraw permanently on, which is the kind of fault
    // that never shows on screen.
    private static let pattern =
        #"(?m)^[ \t]*#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+"# +
        #"([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)[ \t]*"# +
        #"//[ \t]*@[ \t]*([-+]?[0-9]*\.?[0-9]+)[ \t]*\.\.[ \t]*([-+]?[0-9]*\.?[0-9]+)"# +
        #"(?:[ \t]*:[ \t]*([-+]?[0-9]*\.?[0-9]+))?"# +
        #"(.*)$"#

    /// Reserved names are not promoted. Colliding with one of our uniforms would leave
    /// the shader quietly reading the wrong value.
    private static let reserved: Set<String> = [
        "tex", "screen_size", "pointer_position", "time",
        "pointer_pressed_positions", "pointer_pressed_times",
        "v_texcoord", "fragColor", "main",
    ]

    static func parse(_ glsl: String) -> [Knob] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = glsl as NSString
        var out: [Knob] = []
        var seen = Set<String>()

        re.enumerateMatches(in: glsl, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let name = g(1), let dv = g(2).flatMap(Float.init),
                  let lo = g(3).flatMap(Float.init), let hi = g(4).flatMap(Float.init),
                  !reserved.contains(name), !seen.contains(name) else { return }
            seen.insert(name)
            out.append(Knob(name: name, defaultValue: dv, min: lo, max: hi,
                            step: g(5).flatMap(Float.init),
                            doc: docAbove(glsl: ns, defineStart: m.range.location),
                            gatesMotion: g(6)?.contains("!motion") ?? false))
        }
        return out
    }

    /// The run of `//` comment lines directly above the #define. A blank line ends it.
    private static func docAbove(glsl ns: NSString, defineStart: Int) -> String {
        let head = ns.substring(to: defineStart)
        var lines = head.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeLast() }   // the part of the line before the #define
        var doc: [String] = []
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") {
                doc.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else { break }
        }
        return doc.reversed().joined(separator: "\n")
    }
}

/// Every knob of the chain in force. The capture queue (reading) and the control socket
/// and menu (writing) touch it together, so it needs a lock.
///
/// ── Why they are kept per pass ───────────────────────────────────────────
/// Two shaders in a chain collide on names. Both `crt.frag` and `bloom.frag` declaring
/// `CONTRAST` is not odd but likely — each was written assuming it would run alone. One
/// value per name would let a single slider push both shaders, which is the kind of
/// confusion that cannot be fixed.
///
/// So values are held per pass, and the name used from outside carries the pass number
/// in front, as in `2.CONTRAST` (1-based — the same number the menu shows). A bare name
/// is still accepted **when it is unique across the whole chain**, because in the common
/// case of a single shader `--set CURVE 0.2` has to keep working.
final class ChainKnobs {

    struct PassKnobs {
        let path: String
        let knobs: [Knob]
        /// Why promotion was folded, if it was. set returns it verbatim on refusal.
        let demoted: String?
        var values: [String: Float]

        var shaderName: String { (path as NSString).lastPathComponent }
    }

    /// Whether this slot is moving **right now**. `nil` means the shader did not declare
    /// it, and the caller then falls back to looking for `time` in the source.
    ///
    /// ── Why this is needed ───────────────────────────────────────────────
    /// Looking for `time` in the source answers the question only while the moving and
    /// the still variants are two separate files.
    ///
    /// One file that covers both (see the top of crt.frag) breaks that. It still contains
    /// `time` with grain at 0, so the answer is always on, and the property of costing
    /// nothing on a still screen cannot be recovered from a knob.
    ///
    /// So the shader declares it with `!motion` next to the `@range`. With every marked
    /// knob at 0, nothing is moving.
    ///
    /// **A slot whose promotion was folded has empty `knobs` and so falls to nil on its
    /// own.** Which is the right answer — without promotion the values are whatever
    /// constants are baked into the file and we know nothing, and when in doubt, on is
    /// the safe side (being wrong costs battery; it does not freeze the screen).
    static func motionGate(_ p: PassKnobs) -> Bool? {
        let gates = p.knobs.filter { $0.gatesMotion }
        guard !gates.isEmpty else { return nil }
        return gates.contains { (p.values[$0.name] ?? $0.defaultValue) != 0 }
    }

    private let lock = NSLock()
    private(set) var passes: [PassKnobs] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return passes.reduce(0) { $0 + $1.knobs.count }
    }

    func snapshot() -> [PassKnobs] {
        lock.lock(); defer { lock.unlock() }
        return passes
    }

    /// When the chain has been read afresh.
    ///
    /// **The same file still in the same slot keeps its current values.** So that saving
    /// an unrelated edit to a shader does not move sliders you had set. With a chain,
    /// "the same file" turns ambiguous — putting the same shader in twice is a legitimate
    /// use — so the match counts which occurrence of that file it is.
    ///
    /// seeds are the values from the config file or a profile.
    ///
    /// With preferSeeds on, those beat the current values. That is what applying a profile
    /// wants: with the same shader in two profiles, keeping the current values would mean
    /// switching profiles changes the label and not the knobs.
    func adopt(_ incoming: [(path: String, knobs: [Knob], demoted: String?)],
               seeds: [[String: Float]], preferSeeds: Bool = false) {
        lock.lock(); defer { lock.unlock() }

        // File names can repeat, so the key is "path#nth".
        func keyed<T>(_ items: [T], path: (T) -> String) -> [String] {
            var n: [String: Int] = [:]
            return items.map { it in
                let p = path(it)
                let i = n[p, default: 0]
                n[p] = i + 1
                return "\(p)#\(i)"
            }
        }
        let oldKeys = keyed(passes) { $0.path }
        var oldValues: [String: [String: Float]] = [:]
        for (i, k) in oldKeys.enumerated() { oldValues[k] = passes[i].values }

        let newKeys = keyed(incoming) { $0.path }
        var next: [PassKnobs] = []
        for (i, p) in incoming.enumerated() {
            let carried = oldValues[newKeys[i]] ?? [:]
            let seed = i < seeds.count ? seeds[i] : [:]
            var v: [String: Float] = [:]
            for k in p.knobs {
                let raw = preferSeeds ? (seed[k.name] ?? carried[k.name] ?? k.defaultValue)
                                      : (carried[k.name] ?? seed[k.name] ?? k.defaultValue)
                v[k.name] = Swift.min(Swift.max(raw, k.min), k.max)
            }
            next.append(PassKnobs(path: p.path, knobs: p.knobs, demoted: p.demoted, values: v))
        }
        passes = next
    }

    /// One pass's values in the order the shader declared them. Must match the UBO tail order.
    func ordered(pass i: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard i >= 0, i < passes.count else { return [] }
        let p = passes[i]
        return p.knobs.map { p.values[$0.name] ?? $0.defaultValue }
    }

    /// What is saved to settings and profiles. **Only what differs from the default** —
    /// so a profile does not cling to an old default after the shader file's changes.
    func changedValues(pass i: Int) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        guard i >= 0, i < passes.count else { return [:] }
        let p = passes[i]
        var out: [String: Float] = [:]
        for k in p.knobs where p.values[k.name] != k.defaultValue {
            out[k.name] = p.values[k.name]
        }
        return out
    }

    // MARK: Resolving names

    // ── The reason strings below are not translated ──────────────────────
    //
    // They go out through exactly one place: the control socket (the `set` command in
    // main.swift). The menu discards the return value while pushing a slider — it only
    // ever sends values it already knows.
    //
    // The socket is read by programs, not people. An answer that changed with a language
    // setting would break anything that branches on the reason. Stability comes before a
    // friendlier string here, so this is pinned to English.
    enum Resolved {
        case ok(pass: Int, name: String)
        case notFound(String)
        case ambiguous(String)
    }

    /// "2.CURVE" or "CURVE". The latter only when it is unique across the whole chain.
    func resolve(_ id: String) -> Resolved {
        lock.lock(); defer { lock.unlock() }
        return resolveLocked(id)
    }

    private func resolveLocked(_ id: String) -> Resolved {
        if let dot = id.firstIndex(of: "."),
           let n = Int(id[id.startIndex..<dot]), n >= 1 {
            let name = String(id[id.index(after: dot)...])
            guard n <= passes.count else {
                return .notFound("no pass \(n) in the chain (\(passes.count) now)")
            }
            guard passes[n - 1].knobs.contains(where: { $0.name == name }) else {
                return .notFound("no such knob in \(passes[n - 1].shaderName): \(name)")
            }
            return .ok(pass: n - 1, name: name)
        }
        let hits = passes.indices.filter { passes[$0].knobs.contains { $0.name == id } }
        switch hits.count {
        case 0:  return .notFound("no such knob: \(id)")
        case 1:  return .ok(pass: hits[0], name: id)
        default:
            let list = hits.map { "\($0 + 1).\(id) (\(passes[$0].shaderName))" }.joined(separator: ", ")
            return .ambiguous("ambiguous name — prefix it with the pass number: \(list)")
        }
    }

    /// nil on success, otherwise a reason a person can read.
    func set(_ id: String, _ v: Float) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch resolveLocked(id) {
        case .notFound(let m), .ambiguous(let m): return m
        case .ok(let i, let name):
            // Do not pretend to succeed on a shader whose promotion was folded. A slider
            // that appears to do nothing is the worst failure there is.
            if let d = passes[i].demoted {
                return "\(passes[i].shaderName) cannot use knobs — "
                     + (d.split(separator: "\n").first.map(String.init) ?? d)
            }
            guard let k = passes[i].knobs.first(where: { $0.name == name }) else { return nil }
            // Out of range is clamped. The declared range is the interval where the value
            // means something, and outside it some shaders produce NaN (a negative base
            // under pow, for one).
            passes[i].values[name] = Swift.min(Swift.max(v, k.min), k.max)
            return nil
        }
    }

    /// nil id resets everything. A pass alone, like "2.", resets that slot.
    func reset(_ id: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let id else {
            for i in passes.indices {
                for k in passes[i].knobs { passes[i].values[k.name] = k.defaultValue }
            }
            return nil
        }
        if id.hasSuffix("."), let n = Int(id.dropLast()), n >= 1, n <= passes.count {
            for k in passes[n - 1].knobs { passes[n - 1].values[k.name] = k.defaultValue }
            return nil
        }
        switch resolveLocked(id) {
        case .notFound(let m), .ambiguous(let m): return m
        case .ok(let i, let name):
            if let k = passes[i].knobs.first(where: { $0.name == name }) {
                passes[i].values[name] = k.defaultValue
            }
            return nil
        }
    }

    func json() -> String {
        lock.lock(); defer { lock.unlock() }
        var items: [String] = []
        for (i, p) in passes.enumerated() {
            for k in p.knobs {
                items.append(k.json(id: "\(i + 1).\(k.name)", pass: i + 1,
                                    shader: p.shaderName,
                                    value: p.values[k.name] ?? k.defaultValue))
            }
        }
        return "[" + items.joined(separator: ",") + "]"
    }
}
