# plan/ — getting ready to go public

This folder is the working list for making the repo something other people can use.
Nothing here is about shaders or rendering — that side already works. What is here is
**repo shape**: does the build run off this machine, do the strings come out in more
than one language, is the version in one place, does the naming mean anything to
somebody else.

## Where it stands

**Everything below is done except the screenshots** (57 of 58). What is left needs a
person in front of a machine (screenshot, GIF).

What is finished, in summary:

| | |
|---|---|
| Languages | 158 strings in en · ko. The generator stops the build on a missing translation |
| Version | one `VERSION` file → `Info.plist` · `--version` · `--status` · release zip |
| Dependencies | `tool()` checks five places. The `Contents/Helpers/` slot in the bundle is open |
| Build | Homebrew first, nix as fallback. `GS_ARCHS` for universal. Deployment target 14.0 → **13.0** |
| Release | `tools/release.sh` — only the signing section is empty |
| Homebrew | `Formula/global-shader.rb`, with this repo as its own tap. A formula, not a cask, so no account is involved |
| CI | build · `--check` every shader · version agreement · both languages · translation holes |
| Naming | twelve references to a personal repo cleaned up. Bundle ID down to one `Ident` |
| Documentation | short `README.md`/`README.ko.md` + nine `docs/` topics × two languages + `CONTRIBUTING.md` |
| Source language | comments, scripts, and shader headers are English; the Korean lives in `i18n/ko.json` and `*.ko.md` |

## Two premises this hangs on

**There is no paid Apple Developer account.** So it cannot be notarized, and without
notarization it cannot ship through a Homebrew Cask — a cask puts quarantine on the zip
it fetches and Gatekeeper stops a self-signed app. The header of
`tools/make-signing-cert.sh` already says as much.

**But that is a premise about casks, not about brew.** A formula builds on the machine it
installs on, so nothing is downloaded as an app, nothing is quarantined, and Gatekeeper
has nothing to check — an account never enters it. So the tap ships now, as a source
formula (`Formula/global-shader.rb`, this repo being its own tap), and what waits for an
account is the cask alone.

What the formula pays instead is one thing, written down in
[`docs/install.md`](../docs/install.md): every install builds the app fresh and ad-hoc
signed, so Screen Recording permission has to be granted again after an upgrade. The
certificate that fixes this for a clone cannot fix it from inside a formula — Homebrew
builds in a sandbox that denies `~/Library/Keychains` and hands the build a throwaway
`HOME`, and since brew 6 there is no opting out. Re-signing the installed bundle from
one's own shell is the way around it, and it produces the identical requirement.

For the cask, the goal is still set the same way:

> Finish everything ahead of it now, so that on the day an account exists **inserting one
> signing and notarization step** is all a release takes.

Concretely, `tools/release.sh` builds all the way to the zip and leaves the signing
section empty. Two lines — `codesign --options runtime` and `notarytool submit` — go in
there and it is done.

**The repo is public as of this list being finished.** Going public came after it, not
before. The reason for that order is in the "Naming and traces" section of
[`repo-shape.md`](repo-shape.md) — the source held more than ten sentences that only
somebody who knows `~/nixos-config` could read, and fixing them after publishing would
have left that state in the history.

## Documents

| | |
|---|---|
| [`i18n.md`](i18n.md) | Language support. New functionality, so it starts from the design. |
| [`repo-shape.md`](repo-shape.md) | Build, version, dependencies, CI, documentation, naming. |

## Order

i18n comes first. It touches strings, so **doing it later means sweeping every line of
code written in between.** The remaining items barely produce any strings.

```
1. i18n            lift 190 human-facing strings into a table    ← the largest
2. version · deps  one VERSION file, Homebrew prefix search
3. build/release   demote nix to an option, write release.sh
4. CI              build on a macOS runner + --check every shader
5. naming · docs   clean up nixos-config traces, bilingual README
6. (go public)
7. brew tap        a source formula — no account needed, so it does not wait
8. (account → signing · notarization → cask)
```

## Full checklist

### 1. Languages — details in [`i18n.md`](i18n.md)

- [x] Settle the `i18n/en.json` · `i18n/ko.json` schema and create the empty files
- [x] `tools/gen-strings.swift` — the JSON → `Sources/Strings.swift` generator
      (a missing key **stops the build**)
- [x] Have `build.sh` call it alongside `Generated.swift`
- [x] Language resolution order: `--lang` → `GS_LANG` → `lang` in `config.json` → system → en
- [x] Move the 87 strings in `Menu.swift` — the largest and most visible block
- [x] 69 in `main.swift` — one `usage` block plus log and status strings
- [x] 34 across the remaining 6 files — error and status strings
- [x] **Control socket replies are not moved.** It is a protocol, so it stays English (see i18n.md)
- [x] `CFBundleLocalizations` in `Info.plist` — check that it appears in the per-app
      language picker in System Settings
- [x] Decide whether to add `Settings → Language` to the menu (skip it if System
      Settings is enough)

### 2. Version and dependencies

- [x] One `VERSION` file as the single source → `Info.plist` · `--version` · release zip name
- [x] **There is no `--version` flag at all.** Add one
- [x] Add `/opt/homebrew/bin` · `/usr/local/bin` as explicit candidates in `tool()` in
      `ShaderSource.swift` — launched from Finder or launchd they are not in `PATH`, so
      all three currently fail
- [x] Put the inside of the bundle at the front of that same `tool()` search. If the
      tools ever move into the bundle, only copying files is left —
      [`repo-shape.md`](repo-shape.md) measures all five branches (bundling +11 MB,
      licences checked, downloading over the network ruled out)
- [x] The error text in `ShaderSource.swift` only points at `nix shell` → also
      `brew install glslang spirv-cross`
- [x] Bundle ID down to one constant (`dev.jh.global-shader` was written out separately
      in four places: socket, lock, agent label, hint text)

### 3. Build and release

- [x] Demote the `nix build` fallback in `build.sh` to an option — `PATH` and the
      Homebrew prefix are the default, nix is used if present
- [x] Unpin `arm64`: make it universal, or write down that it cannot be
- [x] `tools/release.sh` — build → (signing section) → zip → print sha256
- [x] `LSMinimumSystemVersion` — 14.0 had no basis. **Lowered to 13.0.** The one thing
      blocking 12.3 is the single `cfg.capturesAudio = false` line, but with no machine
      to check it on, it does not go that far
- [x] `Formula/global-shader.rb` — a source formula, which is the half of Homebrew that
      does not need an account. The repo is tapped directly, so there is no second
      repository to keep in step
- [x] `GS_GLSLANG` · `GS_SPIRV_CROSS` in `build.sh`. A packager has to be able to name
      the tools: what `command -v` finds under Homebrew is the Cellar path of today's
      version, and that path is gone after `brew upgrade glslang`
- [x] `tools/update-formula.sh` — writes the tag's tarball url and sha256 into the
      formula. Until the first tag the formula is head-only, which Homebrew installs from
      `main` on its own

### 4. CI

- [x] `.github/workflows/ci.yml` — macOS runner, `brew install glslang spirv-cross`,
      `./build.sh`
- [x] `--check` every `shaders/**/*.frag` in the same workflow. It runs with no window
      and no permission, so it works as is in CI — **the cheapest regression defence in
      this repo**
- [x] A workflow that runs `release.sh` on a pushed tag and drafts a Release
- [x] A second job that installs the formula the way somebody else would — a throwaway
      tap, a tarball of the checkout, `brew install` · `brew test`. `./build.sh` passing
      says nothing about the parts a formula adds

### 5. Naming and documentation

- [x] Rewrite ten references to `~/nixos-config` · `rice-crt` · `rice-knobs` ·
      `workspacepeek` as sentences that stand on their own (not deleted — the reasoning
      stays, only the pointers go)
- [x] 992 lines of `README.md` into English → `README.md` (en) + `README.ko.md`
- [x] Then split those 1200 lines into eight `docs/` topics. The root README keeps only
      "what this is and how to build it" — making a first-time reader scroll 1200 lines
      to find the install steps is not documentation
- [x] Comments, scripts, shader headers, and translator notes in English. Korean stays
      where it is read as Korean: `i18n/ko.json` and the `*.ko.md` documents
- [ ] A screenshot or a short GIF. Nobody looks at a shader app without one
      — **only a person can do this.** It has to show the screen actually covered, and
      by default this app does not appear in screenshots (feedback defence). It has to
      be launched with `--capturable` and captured, and that is the job of whoever is
      sitting at the machine
- [x] `CONTRIBUTING.md` — how to add a shader (the two conventions, verifying with `--check`)
- [x] `plan/` is **not** in `.gitignore` — these documents are committed

### 6. Deferred

Things **deliberately** left off this list, written down so that a later reading does not
ask "was this forgotten".

| | Why deferred |
|---|---|
| A test framework (`Package.swift` + `swift test`) | CI running `--check` catches 90% of regressions. The one place that genuinely wants unit tests is the parser in `ShaderSource`, and that gets them when it does |
| Translating shader comments | Not forbidden, a question of worth. The headers argue at length about each value, and keeping two versions in step costs more than a slider tooltip does. If it is ever needed it goes outside, in `shaders/README.md` — see [`i18n.md`](i18n.md) |
| Signing · notarization · cask | Needs a paid account. The formula does not, and shipped ahead of it |
| Going public | After all of the above |
