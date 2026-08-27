import Foundation

// Where the language is decided. The table itself is in Sources/Strings.swift, which
// tools/gen-strings.swift builds from i18n/*.json.
//
// ── Why it is decided once, at startup ────────────────────────────────────
// A language that changes mid-run splits the log already written from the log still to
// come. The menu is rebuilt every time it opens, so a change shows there immediately,
// but a log cannot be rewound. So the process decides once at startup and freezes it —
// a change from the menu persists to settings and takes effect from the next run.
enum Lang {

    private(set) nonisolated(unsafe) static var current: LangCode = .en

    /// Four places, and the earlier one wins.
    ///
    ///   --lang ko        this run only; for reproducing something
    ///   GS_LANG=ko       environment variable; the place launchd can set it
    ///   config.json      where a change from the menu lands
    ///   system settings  when nothing else was chosen
    ///
    /// And en last. A system language this build does not carry falls through to here.
    static func resolve(cli: String?, config: String?) {
        for candidate in [cli, ProcessInfo.processInfo.environment["GS_LANG"], config] {
            if let c = candidate, let code = match(c) { current = code; return }
        }
        for pref in Locale.preferredLanguages {
            if let code = match(pref) { current = code; return }
        }
        current = .en
    }

    /// What a person typed and what the system hands over arrive at the same door.
    /// `ko` · `ko-KR` · `ko_KR` · `KO` all mean the same thing — without this, the
    /// `ko-KR` from `Locale.preferredLanguages` would match nothing at all.
    static func match(_ raw: String) -> LangCode? {
        let head = raw.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        return LangCode(rawValue: head)
    }

    /// Decide the language **before** parsing the arguments properly.
    ///
    /// Otherwise every error the parser raises comes out in English — `--lang ko
    /// --scale x` would name a language and still be scolded in English, which does
    /// not add up. So argv is swept once for `--lang` alone. A bad value is simply
    /// ignored here — complaining about it is the parser's job, and that complaint
    /// belongs in the configured or system language.
    static func resolveEarly(argv: [String]) {
        var cli: String?
        if let i = argv.firstIndex(of: "--lang"), i + 1 < argv.count { cli = argv[i + 1] }
        resolve(cli: cli, config: ConfigStore.shared.config.lang)
    }

    /// A language a person picked from the menu. Written to settings and applied at once.
    ///
    /// The one exception to deciding only at startup. The rule exists so a run does not
    /// split from the log already written, but at the moment someone **changes the
    /// language themselves** that split is expected, and a UI that did not follow would
    /// be far stranger. The menu is rebuilt on every open, so the next open is in the
    /// new language.
    static func choose(_ raw: String?) {
        ConfigStore.shared.config.lang = raw
        ConfigStore.shared.save()
        resolve(cli: nil, config: raw)
    }

    /// What speakers of a language call their own language. Someone looking for theirs
    /// in the list may not be able to read the language currently on screen, so the list
    /// alone is always written in each language's own name.
    static func displayName(_ c: LangCode) -> String {
        let l = Locale(identifier: c.rawValue)
        guard let n = l.localizedString(forLanguageCode: c.rawValue) else { return c.rawValue }
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    /// So `--lang` can show what it would have accepted.
    static var available: String {
        LangCode.allCases.map(\.rawValue).joined(separator: " ")
    }
}
