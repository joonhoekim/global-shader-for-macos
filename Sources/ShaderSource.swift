import Foundation

// Moves one sheet of GLSL to one sheet of MSL. Two stages: glslang for SPIR-V, then
// spirv-cross for MSL.
//
// Why no hand-written string-substituting transpiler: the shaders this repo has to run
// are things like crt.frag, full of fwidth, loops, and functions broken apart, and a
// hand-rolled substituter goes quietly wrong on some expression. A tool whose mistakes
// you have to notice by looking at the screen is worthless. glslang and spirv-cross are
// the standard route for this conversion, and what they cannot move dies with an error —
// far better than being quietly wrong.
//
// The two binary paths are baked into Generated.swift at build time (build.sh). They are
// absolute paths into the nix store, so launching from Finder finds them without a PATH.

enum ShaderError: Error, CustomStringConvertible {
    case toolMissing(String)
    case compile(stage: String, log: String)

    var description: String {
        switch self {
        case .toolMissing(let t):
            return Str.shader_err_toolMissing(t)
        case .compile(let stage, let log):
            return "[\(stage)]\n\(log)"
        }
    }
}

enum ShaderConvention {
    case hyprland   // main() / tex / screen_size / pointer_position / time
    case shadertoy  // mainImage(out vec4, in vec2) / iChannel0 / iResolution / iTime
}

struct ShaderSource {

    // ── The convention ───────────────────────────────────────────────────
    // There are only these uniforms, and their names and meanings match Hyprland's
    // decoration:screen_shader, because the same .frag file has to run on both platforms.
    //
    //   tex                        one finished frame of the screen. (0,0) is top-left.
    //   screen_size                pixel size of this display (of the drawable)
    //   pointer_position           the cursor. 0..1, top-left origin as well
    //   time                       seconds since launch
    //   pointer_pressed_positions  positions of the last 32 clicks. [0] is the newest.
    //   pointer_pressed_times      seconds **since** each click (as under Hyprland)
    //
    // Vulkan GLSL takes no uniforms outside a block, so they all go into one UBO and the
    // original names are restored with #define. None of this is visible from the shader.
    //
    // The underscores on the field names inside the block look trivial and are required.
    // A field named plainly `time` would let `#define time _gs._time` below re-expand
    // **references inside the block too**, giving `_gs._gs.time`. Code that reads _gs
    // directly after the preamble — the Shadertoy shim — would break there.
    private static func preamble(knobs: [Knob]) -> String {
        // Knobs go on **the tail** of the UBO. In std140 a lone float has alignment 4, so
        // they stack tightly, 4 bytes at a time, from where the preceding array ends
        // (byte 1056). The Swift side (GSGlobals) does the same arithmetic, so the two
        // have to be changed together.
        //
        // The k_ on the field names keeps them from colliding with the #define. With
        // `float CURVE;` and `#define CURVE _gs.CURVE` the macro is self-referential —
        // the C preprocessor stops that, but writing _gs.CURVE anywhere else breaks it.
        // A different name has no such trap.
        let fields = knobs.map { "    float k_\($0.name);" }.joined(separator: "\n")
        let defines = knobs.map { "#define \($0.name) _gs.k_\($0.name)" }.joined(separator: "\n")
        return """
    #version 450 core
    layout(location = 0) in vec2 v_texcoord;
    layout(location = 0) out vec4 fragColor;
    layout(std140, set = 0, binding = 0) uniform GSGlobals {
        vec2 _screen_size;
        vec2 _pointer_position;
        float _time;
        vec2 _pressed_positions[32];
        float _pressed_times[32];
    } _gs;
    #define screen_size               _gs._screen_size
    #define pointer_position          _gs._pointer_position
    #define time                      _gs._time
    #define pointer_pressed_positions _gs._pressed_positions
    #define pointer_pressed_times     _gs._pressed_times
    layout(set = 0, binding = 1) uniform sampler2D tex;

    """
        .replacingOccurrences(of: "    float _pressed_times[32];",
                              with: "    float _pressed_times[32];\n" + fields)
        + defines + (defines.isEmpty ? "" : "\n") + "\n"
    }

    // The shim that lays the Shadertoy convention over the Hyprland one.
    //
    // Two flips is confusing and both are needed. Shadertoy's fragCoord has a bottom-left
    // origin, so main() flips once; reading the screen through a uv built from those
    // coordinates has to come back to top-left, so texture() flips again. The point is
    // defining _gsTex **before** the #define — inside the function body, texture is not
    // yet a macro and so does not call itself.
    private static let shadertoyShim = """
    vec4 _gsTex(sampler2D s, vec2 uv) { return texture(s, vec2(uv.x, 1.0 - uv.y)); }
    #define texture(s, uv) _gsTex(s, uv)
    #define iChannel0   tex
    #define iResolution vec3(_gs._screen_size, 1.0)
    #define iTime       _gs._time
    #define iTimeDelta  (1.0 / 60.0)
    #define iFrame      int(_gs._time * 60.0)
    #define iMouse      vec4(_gs._pointer_position * _gs._screen_size, 0.0, 0.0)
    void mainImage(out vec4 fragColorOut, in vec2 fragCoord);
    void main() {
        vec2 fc = vec2(v_texcoord.x, 1.0 - v_texcoord.y) * _gs._screen_size;
        vec4 c = vec4(0.0, 0.0, 0.0, 1.0);
        mainImage(c, fc);
        fragColor = c;
    }

    """

    // Lines the original declared under its own convention. They overlap our preamble, so
    // they are stripped. Only the exact names listed here are removed — another uniform
    // or in/out the shader made itself has to survive so glslang can properly complain
    // that there is no such thing.
    //
    // (?m) is mandatory. Swift's replacingOccurrences(.regularExpression) runs
    // NSRegularExpression with default options, so ^ and $ match only the start and end
    // of the whole string — in that state none of these lines is removed at all, and
    // glslang dies with "#version must occur first".
    //
    // Only #version is caught loosely with .*$, to take a trailing comment with it. The
    // rest pick out exactly one declaration ending in a semicolon.
    private static let stripPatterns: [String] = [
        #"(?m)^[ \t]*#version\b.*$"#,
        #"(?m)^[ \t]*precision\s+\w+\s+\w+\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*(layout\s*\([^)]*\)\s*)?in\s+vec2\s+v_texcoord\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*(layout\s*\([^)]*\)\s*)?out\s+vec4\s+fragColor\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*uniform\s+sampler2D\s+tex\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*uniform\s+vec2\s+(screen_size|pointer_position)\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*uniform\s+float\s+time\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*uniform\s+vec2\s+pointer_pressed_positions\s*\[[^\]]*\]\s*;[ \t]*(//.*)?$"#,
        #"(?m)^[ \t]*uniform\s+float\s+pointer_pressed_times\s*\[[^\]]*\]\s*;[ \t]*(//.*)?$"#,
    ]

    static func convention(of glsl: String) -> ShaderConvention {
        // Not trying to catch a declaration with no body. The one practical marker
        // separating the two conventions is whether mainImage exists.
        return glsl.range(of: #"\bmainImage\s*\("#, options: .regularExpression) != nil
            ? .shadertoy : .hyprland
    }

    /// One file to MSL source. The thrown error message is read by a person verbatim.
    struct Result {
        let msl: String
        let knobs: [Knob]
        /// Why promotion was tried and folded. nil means it was not.
        let demoted: String?
    }

    /// Knob promotion is **on by default and folds quietly on failure.**
    ///
    /// Why the fold has to exist: promotion turns a constant into a uniform, so a value
    /// used somewhere that requires a constant fails the whole compile.
    ///
    ///     #define TAPS 8   // @1..16
    ///     float w[TAPS];   → array size must be a constant integer expression
    ///
    /// Without the fallback, such a shader drops to a passthrough the moment promotion is
    /// on by default — something that worked yesterday and does not today, the worst kind
    /// of regression. Folded, that shader runs exactly as before, minus the knobs.
    ///
    /// If both fail, **the error from the un-promoted attempt** is thrown. That is the
    /// shader's own problem, and showing someone a side error caused by promotion only
    /// confuses.
    static func translate(path: String, promoteKnobs: Bool) throws -> Result {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let name = (path as NSString).lastPathComponent
        guard promoteKnobs else {
            return try translate(glsl: raw, name: name, promoteKnobs: false)
        }
        do {
            return try translate(glsl: raw, name: name, promoteKnobs: true)
        } catch {
            let plain = try translate(glsl: raw, name: name, promoteKnobs: false)
            return Result(msl: plain.msl, knobs: [],
                          demoted: Str.shader_demoted("\(error)"))
        }
    }

    static func translate(glsl raw: String, name: String, promoteKnobs: Bool) throws -> Result {
        let knobs = promoteKnobs ? KnobParser.parse(raw) : []

        var body = raw
        for p in stripPatterns {
            body = body.replacingOccurrences(
                of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Strip the #define of anything promoted. Left in place, the macro overwrites the
        // uniform name and the value never changes — a slider that quietly does nothing.
        for k in knobs {
            let pat = #"(?m)^[ \t]*#define[ \t]+"# + NSRegularExpression.escapedPattern(for: k.name)
                    + #"[ \t]+.*$"#
            body = body.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }

        var merged = preamble(knobs: knobs)
        if convention(of: raw) == .shadertoy { merged += shadertoyShim }
        merged += body

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frag = tmp.appendingPathComponent("merged.frag")
        let spv = tmp.appendingPathComponent("out.spv")
        try merged.write(to: frag, atomically: true, encoding: .utf8)

        let glslang = try tool(Tools.glslang, "glslang")
        let cross = try tool(Tools.spirvCross, "spirv-cross")

        let g = run(glslang, ["-V", "--target-env", "vulkan1.0", "-S", "frag",
                              frag.path, "-o", spv.path])
        guard g.status == 0 else {
            throw ShaderError.compile(
                stage: "\(name) → SPIR-V",
                log: rewriteLineNumbers(tidy(g.output, tempPath: frag.path, name: name),
                                        merged: merged, raw: raw, name: name))
        }

        // --msl-decoration-binding is what carries GLSL's binding numbers straight over
        // to MSL's buffer/texture/sampler numbers. Without it spirv-cross renumbers from
        // 0 as it pleases, and Renderer has no way to know where to bind.
        let c = run(cross, [spv.path, "--msl", "--msl-version", "20100",
                            "--msl-decoration-binding", "--stage", "frag",
                            "--entry", "main"])
        guard c.status == 0 else {
            throw ShaderError.compile(stage: "\(name) → MSL", log: c.output)
        }
        return Result(msl: c.output, knobs: knobs, demoted: nil)
    }

    // ── Does this shader have to be redrawn continuously ─────────────────
    //
    // The same judgement as whether to turn off debug:vfr under Hyprland, on the same
    // basis — a shader that reads time has to keep being drawn to move, even with nothing
    // changing on screen. Decided from the file rather than by asking.
    //
    // **Stripping comments first is the crux.** This repo's shaders write at length about
    // why they do what they do, and mention `time` often inside that prose. Counted
    // without stripping:
    //
    //   glow.glsl   1 with comments → 0 in code
    //   neon.frag   1 with comments → 0 in code
    //   crt.frag    8 with comments → 4 in code
    //
    // And the single hit in the first two is **the sentence saying it is not used** —
    // glow.glsl notes that animation is off because it does not use iTime, and neon.frag
    // that it has no flicker because reading `time` even once switches redraw on. Without
    // stripping, the sentence disclaiming it would rule both always-on, and a still screen
    // would drive the GPU at the refresh rate with nothing moving at all. Stripped, they
    // split cleanly at 0 · 0 against 4.
    //
    // The direction of a misjudgement is the safe one — being wrong costs battery; it does
    // not freeze the screen.
    static func needsContinuousRedraw(_ glsl: String) -> Bool {
        let code = glsl
            .replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)//.*$"#, with: " ", options: .regularExpression)
        let moving = #"\b(time|iTime|iTimeDelta|iFrame|pointer_pressed_times)\b"#
        return code.range(of: moving, options: .regularExpression) != nil
    }

    // ── Finding the tools ────────────────────────────────────────────────
    //
    // Five places, in order.
    //
    //   1. GS_GLSLANG / GS_SPIRV_CROSS   named outright by a person. Always wins.
    //   2. Contents/Helpers/ in bundle   what we shipped (empty for now)
    //   3. absolute path baked by build.sh   what this build actually built against
    //   4. Homebrew prefix               see below
    //   5. PATH
    //
    // ── Why the Homebrew paths are written out by hand ───────────────────
    // Surely reading PATH would do — except that **a process launched from Finder or
    // launchd has no /opt/homebrew/bin in its PATH.** What it inherits there is
    // /usr/bin:/bin:/usr/sbin:/sbin and nothing else. The reason build.sh's header gives
    // for the nix profile applies to Homebrew identically.
    //
    // What makes it nasty is that the symptom splits — it works from a terminal and not
    // from the icon. Someone who has not hit it before blames the shader.
    //
    // ── Why slot 2 is empty ──────────────────────────────────────────────
    // Putting the tools in the bundle removes the external dependency (branch C in
    // plan/repo-shape.md), and that is work for after there is an account to notarize
    // with. The slot is opened now so that the remaining work then is "copy the files".
    private static func tool(_ baked: String, _ name: String) throws -> String {
        let envKey = "GS_" + name.uppercased().replacingOccurrences(of: "-", with: "_")
        if let e = ProcessInfo.processInfo.environment[envKey],
           FileManager.default.isExecutableFile(atPath: e) { return e }

        if let h = helper(name), FileManager.default.isExecutableFile(atPath: h) { return h }

        if !baked.isEmpty, FileManager.default.isExecutableFile(atPath: baked) { return baked }

        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // Homebrew's prefix on Apple silicon and on Intel. Both are checked — which one
        // applies is settled at install time, not at run time, and a path that is not
        // there simply does not match.
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw ShaderError.toolMissing(name)
    }

    /// `Contents/Helpers/<name>` inside the bundle.
    ///
    /// **Bundle.main.bundleURL must not be used.** The `build/global-shader` that build.sh
    /// creates is a symlink to the executable inside the bundle, and that is the way the
    /// README suggests running it. Launched through that symlink, Bundle.main takes the
    /// folder holding the symlink (`build/`) for the bundle rather than the `.app`:
    ///
    ///     ./build/global-shader   bundleURL → …/build          ← wrong
    ///     .app/Contents/MacOS/…   bundleURL → …/GlobalShader.app
    ///
    /// Resolving executableURL through its symlinks makes both cases point at the same
    /// place. Two levels up from MacOS/ is Contents/.
    ///
    /// Running the bare executable from somewhere arbitrary yields a path that is not
    /// there, which simply does not match and falls through to the next slot.
    private static func helper(_ name: String) -> String? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return exe.deletingLastPathComponent()      // Contents/MacOS
                  .deletingLastPathComponent()      // Contents
                  .appendingPathComponent("Helpers", isDirectory: true)
                  .appendingPathComponent(name).path
    }

    private static func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "\(exe): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Strips the temporary file path out of what glslang emitted.
    ///
    /// We write a copy with the preamble attached into a temporary folder and compile
    /// that, so errors read like `/var/folders/…/gs-A639C99C-…/merged.frag:20:`. That path
    /// means nothing to the person editing the shader, and it hides the real file name.
    /// Since these show in the menu verbatim, it matters more — on a narrow line all you
    /// see is the UUID, and not what is actually wrong.
    ///
    /// A first line that is just an echo of the file name goes too.
    private static func tidy(_ log: String, tempPath: String, name: String) -> String {
        var out = log.replacingOccurrences(of: tempPath, with: name)
        // The temporary folder is removed and remade, so the path differs every time.
        // Anything left (an included file, say) is folded away wholesale.
        out = out.replacingOccurrences(
            of: #"/var/folders/[^\s:]*/gs-[0-9A-F-]+/"#, with: "",
            options: .regularExpression)
        let lines = out.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces) != name
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The line numbers glslang reports are from after the preamble was attached, so they
    // do not match the original. The person editing the shader is looking at the original,
    // so they are put back here.
    //
    // Two shapes occur. `ERROR: 0:123:`, with a source number in front, and
    // `ERROR: crt.frag:123:`, with a file name in front. Which one appears depends on how
    // glslang was called, and both do occur — handling one alone would emit numbers about
    // 20 lines off from the original through the other route.
    private static func rewriteLineNumbers(_ log: String, merged: String, raw: String,
                                           name: String = "") -> String {
        let offset = merged.components(separatedBy: "\n").count
                   - raw.components(separatedBy: "\n").count
        guard offset > 0 else { return log }

        // The stripped uniform lines can throw this off by a line or two, which is still
        // enough to find the right function.
        func shift(_ text: String, pattern: String, headGroup: Int) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
            var out = ""
            var last = text.startIndex
            let ns = text as NSString
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, let r = Range(m.range, in: text),
                      let lr = Range(m.range(at: headGroup + 1), in: text),
                      let n = Int(text[lr]) else { return }
                out += text[last..<r.lowerBound]
                let head = Range(m.range(at: headGroup), in: text).map { String(text[$0]) } ?? ""
                out += "\(head):\(max(1, n - offset)):"
                last = r.upperBound
            }
            out += text[last...]
            return out
        }

        var result = shift(log, pattern: #"(\b\d+):(\d+):"#, headGroup: 1)
        if !name.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = shift(result, pattern: "(" + escaped + #"):(\d+):"#, headGroup: 1)
        }
        return result
    }
}
