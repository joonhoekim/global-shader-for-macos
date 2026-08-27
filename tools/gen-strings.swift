#!/usr/bin/env swift
//
// gen-strings.swift — moves i18n/*.json into Sources/Strings.swift.
//
// ── Why not .lproj ───────────────────────────────────────────────────────
// With no translation, NSLocalizedString puts **the key itself** on screen. It does not
// die, it does not warn, and only someone running in that language ever sees it. This
// repo has refused that failure twice already — the hand-written GLSL substituter
// (quietly wrong values) and the slider on a still screen (a value that quietly does
// nothing). There is no reason to break the rule only here.
//
// So the table is generated as code. Two things follow:
//
//   1. A missing translation **stops the build.** This file exits non-zero.
//   2. Placeholder count and types are baked into the signature, so a caller that gets
//      them wrong does not compile.
//
// As a bonus, nothing is read from the bundle at run time. --check is the mode that runs
// with no window and no permission, and CI validates shaders with it; resource loading in
// the way would create one more place where "it works from the bundle but comes out
// differently in CI". The same reason build.sh bakes the glslang path into
// Generated.swift.
//
// ── Schema ───────────────────────────────────────────────────────────────
// i18n/en.json is the reference. It decides the key set.
//
//   {
//     "menu.chain.moveUp": { "en": "Move up" },
//     "knob.err.noPass":   { "args": ["Int", "Int"],
//                            "en": "no pass %1$d in the chain (%2$d now)",
//                            "note": "seen only by whoever translates it" }
//   }
//
// i18n/<code>.json holds the same keys with strings alone: { "menu.chain.moveUp": "위로" }
//
// Placeholders must be **positional** — %1$@ · %2$d. Word order differs by language, and
// a bare %@ cannot be reordered in translation.
//
//   swift tools/gen-strings.swift i18n Sources/Strings.swift
//
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: gen-strings.swift <i18n-dir> <out.swift>\n".data(using: .utf8)!)
    exit(2)
}
let dir = args[1], outPath = args[2]

func die(_ lines: [String]) -> Never {
    FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    exit(1)
}

// ── Reading ──────────────────────────────────────────────────────────────

func loadJSON(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path) else { die(["cannot read: \(path)"]) }
    guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        die(["not JSON: \(path)"])
    }
    return o
}

let basePath = dir + "/en.json"
let base = loadJSON(basePath)

/// The languages besides en.json. The files are the language list.
let others = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    .filter { $0.hasSuffix(".json") && $0 != "en.json" }
    .map { String($0.dropLast(5)) }
    .sorted()
let langs = ["en"] + others

var tables: [String: [String: String]] = [:]
for l in others {
    tables[l] = loadJSON(dir + "/\(l).json").compactMapValues { $0 as? String }
}

// ── Unpacking the reference table ────────────────────────────────────────

struct Entry {
    let key: String
    let argTypes: [String]
    let note: String?
    var text: [String: String] = [:]   // language code → string
}

let allowedArgs: Set<String> = ["String", "Int", "Double"]
var entries: [Entry] = []
var problems: [String] = []

for key in base.keys.sorted() {
    guard let o = base[key] as? [String: Any] else {
        problems.append("\(key): the value in en.json is not an object"); continue
    }
    guard let en = o["en"] as? String else {
        problems.append("\(key): no en"); continue
    }
    let argTypes = (o["args"] as? [String]) ?? []
    for t in argTypes where !allowedArgs.contains(t) {
        problems.append("\(key): unknown argument type '\(t)' — only String · Int · Double")
    }
    guard key.range(of: "^[a-z][A-Za-z0-9]*(\\.[a-zA-Z0-9]+)*$", options: .regularExpression) != nil else {
        problems.append("\(key): not a key (starts lowercase, separated by dots)"); continue
    }
    var e = Entry(key: key, argTypes: argTypes, note: o["note"] as? String)
    e.text["en"] = en
    entries.append(e)
}

// ── Is every translation there ───────────────────────────────────────────
//
// This is why the file exists. **Every** missing one is collected and printed at once —
// reporting them one at a time means fixing and rerunning that many times.

for l in others {
    let t = tables[l]!
    let missing = entries.filter { t[$0.key] == nil }.map(\.key)
    if !missing.isEmpty {
        problems.append("i18n/\(l).json is missing \(missing.count):")
        problems.append(contentsOf: missing.map { "    " + $0 })
    }
    let known = Set(entries.map(\.key))
    let stale = t.keys.filter { !known.contains($0) }.sorted()
    if !stale.isEmpty {
        // Where something was renamed and the old key was not removed. Left in place, the
        // next person takes it for something in use and edits it.
        problems.append("i18n/\(l).json has \(stale.count) key(s) not in en.json:")
        problems.append(contentsOf: stale.map { "    " + $0 })
    }
}

// ── Do the placeholders match across languages ───────────────────────────
//
// Dropping %2$@ while translating leaves the name missing in that language alone.
// String(format:) does not die, so it has to be caught by looking at the screen — which
// is the very thing this file exists to remove.

func placeholders(_ s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "%(\\d+)\\$[@dif.0-9]*[@dif]")
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
        .sorted()
}

for i in entries.indices {
    let e = entries[i]
    let want = (1...max(e.argTypes.count, 1)).map(String.init)
    let expected = e.argTypes.isEmpty ? [] : Array(want.prefix(e.argTypes.count))
    for l in langs {
        let s = l == "en" ? e.text["en"]! : (tables[l]?[e.key] ?? "")
        if s.isEmpty { continue }
        let got = Array(Set(placeholders(s))).sorted()
        if got != expected {
            problems.append("\(e.key) [\(l)]: placeholders do not match args — "
                          + "\(e.argTypes.count) args, but it uses %\(got.joined(separator: "$ %"))$")
        }
        entries[i].text[l] = s
    }
}

if !problems.isEmpty {
    die(["gen-strings: the translation table does not hold.", ""] + problems + [""])
}

// ── Writing ──────────────────────────────────────────────────────────────
// ── Writing ──────────────────────────────────────────────────────────────
func lit(_ s: String) -> String {
    var o = ""
    for c in s.unicodeScalars {
        switch c {
        case "\\": o += "\\\\"
        case "\"": o += "\\\""
        case "\n": o += "\\n"
        case "\t": o += "\\t"
        case "\r": o += "\\r"
        case "\0": o += "\\0"
        default:   o.unicodeScalars.append(c)
        }
    }
    return "\"" + o + "\""
}

func ident(_ key: String) -> String { key.replacingOccurrences(of: ".", with: "_") }

var out = """
// Generated by tools/gen-strings.swift from i18n/*.json. Do not edit by hand.
//
// To add a string, put the key in i18n/en.json and in every other language file too.
// One missing anywhere stops the build — which is why this file is generated.

/// The languages in this build. The files in i18n/ are the list.
enum LangCode: String, CaseIterable, Sendable {
    case \(langs.joined(separator: "\n    case "))
}

enum Str {

"""

for e in entries {
    if let n = e.note {
        for line in n.split(separator: "\n", omittingEmptySubsequences: false) {
            out += "    /// \(line)\n"
        }
    }
    let name = ident(e.key)
    let body = langs.map { "        case .\($0): \(lit(e.text[$0]!))" }.joined(separator: "\n")
    if e.argTypes.isEmpty {
        out += """
            static var \(name): String {
                switch Lang.current {
        \(body)
                }
            }


        """
    } else {
        let params = e.argTypes.enumerated().map { "_ a\($0.offset + 1): \($0.element)" }
            .joined(separator: ", ")
        let call = e.argTypes.indices.map { "a\($0 + 1)" }.joined(separator: ", ")
        out += """
            static func \(name)(\(params)) -> String {
                let f: String = switch Lang.current {
        \(body)
                }
                return String(format: f, \(call))
            }


        """
    }
}

out += "}\n"

// Not written when nothing changed. The mtime has to stay put or swiftc rebuilds for nothing.
let old = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
if old != out {
    try! out.write(toFile: outPath, atomically: true, encoding: .utf8)
}
print("strings      \(entries.count) · \(langs.joined(separator: " "))")
