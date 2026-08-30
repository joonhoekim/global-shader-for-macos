# Repo shape

Everything except the languages. Ordered not by size but **by what blocks what** — if the
earlier item is not done, the later one is meaningless.

## 1. There is no version anywhere

The version appears once, as `0.1` inside `build.sh`, and that is all. There is no tag and
no `--version` flag. Which means there is no way to ask what is running.

```
VERSION                  0.1.0            ← the single source
  ├→ build.sh            CFBundleShortVersionString
  ├→ Generated.swift     let version = "0.1.0"
  ├→ --version           prints it
  ├→ --status JSON       adds a version key
  └→ release.sh          GlobalShader-0.1.0.zip
```

Putting the version in `--status` matters. It is the first thing to ask about an issue,
and with a hole that already emits JSON, leaving it out means someone has to dig it up by
hand.

`CFBundleVersion` (the build number) is left at `1` or filled with CI's run number. While
there is no notarization, nobody looks at it.

- [x] a `VERSION` file
- [x] `build.sh` reads it into `Info.plist` and `Generated.swift`
- [x] a `--version` / `-V` flag (in `usage` too)
- [x] `version` in the `--status` JSON

## 2. It does not build off this machine

`build.sh` looks for `glslang` and `spirv-cross` in `PATH`, and failing that
**realizes them with `nix build`.** On a Mac without nix it dies right there, and the
error text says *rerun inside `nix shell nixpkgs#...`* (`build.sh`, `ShaderSource.swift`).

This is not about deleting the nix fallback — for a nix user that is the route that
actually works. **The default and the fallback swap places:**

```
1. PATH
2. /opt/homebrew/bin, /usr/local/bin        ← Homebrew. Currently not looked at at all
3. nix build (only when nix is present)
4. die — naming all three routes:
     brew install glslang spirv-cross
     nix shell nixpkgs#glslang nixpkgs#spirv-cross -c ./build.sh
```

Both are in homebrew-core. Confirmed — `glslang 16.4.0`, `spirv-cross 1.4.357.0`, with
arm64 bottles for sonoma, sequoia, and tahoe.

- [x] add the Homebrew prefix to `find_tool` in `build.sh` and move nix behind it
- [x] all three routes in the error text in `ShaderSource.swift`

### The run-time side has the same hole

`tool()` in `ShaderSource.swift` searches **baked path → `GS_GLSLANG` environment
variable → `PATH`**. All three fail on somebody else's machine:

- the baked path is a nix store path from the machine that built it — nobody else has it
- the environment variable will not have been set
- **`PATH` has no `/opt/homebrew/bin`.** A process launched from Finder or launchd has a
  `PATH` of `/usr/bin:/bin:/usr/sbin:/sbin` and nothing more. The reason `build.sh`'s
  header gives for the nix profile applies to Homebrew identically

It is the kind that works from a terminal and not from Finder, so it is unfindable
without having hit it.

- [x] add `/opt/homebrew/bin/<name>` · `/usr/local/bin/<name>` to `tool()`'s candidates
- [x] check that the not-found message reaches the menu too — CLI only means whoever
      launched it from the GUI never sees the reason

### It could be removed entirely — five branches

Fixing the path search leaves the fact that **somebody else has to run
`brew install glslang spirv-cross`** untouched. Every route out of that was measured. The
numbers below come from actually fetching and unpacking the bottles, with standalone
execution tested.

```
the whole app today                             612 KB

spirv-cross   binary 3.1 MB   ★ fully static (libc++ · libSystem only)
glslang       binary 153 KB   ← a shell. The substance is below
  libglslang.dylib                    2.4 MB
  libglslang-default-resource-limits    54 KB
  libSPIRV-Tools.dylib                1.9 MB   ← drags in spirv-tools
  libSPIRV-Tools-opt.dylib            3.5 MB
                                    ─────────
total needed at run time (arm64)     about 11 MB
```

`spirv-cross` copied outside the Homebrew tree and run — **it just works.** Statically
linked, nothing attached. `glslang` is the opposite, dragging four dylibs, and inside the
bottle their paths are unsubstituted placeholders like
`@@HOMEBREW_PREFIX@@/opt/spirv-tools/...`.

Both have a C API — `glslang_c_interface.h`, `spirv_cross_c.h`. Being C, Swift can call
them directly with no C++ interop. Homebrew **already ships static libraries** for
`spirv-cross` (`-c` · `-core` · `-glsl` · `-msl`, 5.3 MB together). `glslang` gives dylibs
only.

| | bundled shaders | other people's shaders | app size | effort |
|---|---|---|---|---|
| **A** fix the path search only | brew needed | brew needed | 612 KB | XS |
| **B** translation cache + prefilled at build | **not needed** | brew needed | +0.5 MB | M |
| **C** binaries inside the `.app` | **not needed** | **not needed** | +11 MB (universal +22) | M |
| **D** static linking (C API) | **not needed** | **not needed** | +6–8 MB | L |
| **E** fetch from the network on first run | — | — | — | **must not** |

#### E goes first

A notarized app runs under hardened runtime, and **executing an unsigned binary it
downloaded is blocked.** Getting past that needs an entitlement like
`com.apple.security.cs.disable-library-validation`, which notarization review asks you to
justify. It does not work offline, integrity has to be verified by hand, and the first run
gets slower.

More fundamentally — **brew already does exactly that job.** `depends_on formula:` is
"fetch from the network, verify, put it in place". Doing it by hand rebuilds brew, and an
app that means to ship as a cask doing so does not add up.

#### C — binaries in the bundle

`spirv-cross` is a copy and nothing else (tested). `glslang` means putting five Mach-Os in
`Contents/Frameworks` and rewriting to `@loader_path` with `install_name_tool -change` —
five or six lines of script. The code change is **one line**, pointing `Tools.glslang`
inside the bundle, and `build.sh` is still one `swiftc` line. No CMake, no submodules.

Three costs:

- **612 KB → 12 MB.** Eighteen times. Whether one shader overlay is worth that is a judgement
- Universal means fetching both the arm64 and the x86_64 bottle and joining them with
  `lipo`. Homebrew bottles are thin, one per architecture
- Notarization means **signing every Mach-O in the bundle.** That becomes six

#### D — static linking

A refinement of C rather than a separate route. It barely reduces size. The gain is
elsewhere:

- **The process spawns disappear.** Today, applying one shader starts two processes and
  writes three temporary files. Hot reload only checks mtime every 0.4 s, so it is not a
  standing cost, but **while a shader is being written** it runs on every save
- **Errors arrive through an API rather than as strings.** `tidy()` and
  `rewriteLineNumbers()` in `ShaderSource` disappear entirely. Both currently lean on
  glslang's output format, so an upstream wording change makes them quietly drift
- One Mach-O to sign

The cost is large. Homebrew ships no static library for `glslang`, so it has to be **built
from source with `BUILD_SHARED_LIBS=OFF`** → submodule plus CMake. Rewriting the two
`run(exe, args)` sites as C API calls is another 150 lines or so. The "one swiftc line,
not an Xcode project" the README takes pride in breaks.

#### B — the cache. Not exclusive with the others

Keep translation results in `~/Library/Caches/…/msl/<content-hash>.metal`, and prefill the
eleven files in `shaders/` at build time and put them in the bundle. `--dump-msl` already
exists, so half the plumbing is laid.

**The dependency drops from "must be installed" to "needed only when adding a new
shader".** But it does nothing for someone **writing** shaders — changing one `#define`
changes the hash and misses the cache. With C done, B is left as a performance
optimization alone.

#### Licences — checked, and nothing blocks

Homebrew records the glslang licence as `BSD-3-Clause AND GPL-3.0-or-later AND MIT AND
Apache-2.0`, which looked like it might block bundling, so it got taken apart.

Per `license-checker.cfg`, GPL-3.0 covers **exactly two files, `glslang_tab.cpp` and
`.cpp.h`** — a bison-generated parser. The Bison Exception is right there in the 923 lines
of `LICENSE.txt`: *"you may create a larger work that contains part or all of the Bison
parser skeleton and distribute that work under terms of your choice."* And five lines
state that **"Bison was removed long ago"**.

Bundling it in an MIT app does not make GPL infectious. The **attribution obligations** of
BSD-3, MIT, and Apache-2.0 do remain.

- [x] `THIRD-PARTY-NOTICES.md` — written ahead of time. It carries the shader attribution
      today and has the slot for the bundled tools' notices when C happens

(Not legal advice; the result of reading the licence files.)

#### Decision

```
now          A — fix the path search only. Keep the brew dependency and describe it precisely
at cask time C — binaries in the bundle. spirv-cross is a copy, glslang needs install_name_tool
when worth   D — static linking. When process spawns and error-string parsing start to grate
any time     B — the cache. It goes with any of the above
never        E
```

**There is one reason C is not done now.** Building a 12 MB app today gets nobody
anything, because it cannot be signed and so cannot be handed to anyone. And the genuinely
hard part of C — signing six Mach-Os — can only be tested with an account. In order it is
one pass; done now it is half-finished and reopened later.

Instead, **A leaves the slot for C open.**

- [x] put the inside of `Bundle.main` (`Contents/Helpers/<name>`) at the front of
      `tool()`'s search order. Then C is reduced to copying files

## 3. It only ships arm64

```sh
swiftc -target arm64-apple-macos14.0 ...
```

It does not run on an Intel Mac. Two branches:

**Make it universal** — split `-target` in two, build twice, `lipo -create`. Five lines of
script, and with this few source files the build time is not a concern. The only obstacle
is having no Intel Mac to verify on, and CI's x86_64 runner fills that (the build and
`--check` are confirmed; a real capture is not).

**Pin it to arm64** — say so in the README and in the eventual cask
(`depends_on arch: :arm64`).

→ **Make it universal and write down that whether it runs on Intel is unknown.** Better to
ship what builds and state what was verified than to withhold it.

- [x] a `lipo` step in `build.sh`
- [x] `LSMinimumSystemVersion` — measured. **Lowered to 13.0.** 14.0 had no basis and 13.0
      builds without a single warning. The one thing blocking 12.3 is
      `cfg.capturesAudio = false` in `Capture.swift` (a line that only spells out the
      default), which `#available` would handle — but claiming two more releases with no
      machine to check them on is another matter. 13 and 14 are confirmed **only as far as
      building**

## 4. Releasing is done by hand

- [x] `tools/release.sh`
      ```
      read VERSION
      build.sh (universal)
      ── signing section ─────────────────────
      # With a paid account, two lines go here:
      #   codesign --options runtime --timestamp --sign "Developer ID Application: …"
      #   xcrun notarytool submit --wait && xcrun stapler staple
      # For now build.sh's self-signature ships as is
      ─────────────────────────────────────────
      ditto -c -k --keepParent → GlobalShader-<ver>.zip
      print shasum -a 256           ← the value that goes straight into the cask
      ```
- [x] the script says at the end that the zip produced at this stage is **something nobody
      else can open**. Otherwise it gets built, uploaded, and comes back as an "is damaged"
      report

## 5. There is no CI

Run this on a macOS runner:

```yaml
brew install glslang spirv-cross
./build.sh
for f in shaders/**/*.frag shaders/**/*.glsl; do
    ./build/global-shader --check "$f"
done
```

**`--check` is the cheapest regression defence in this repo.** It runs with no window and
no Screen Recording permission, so it works as is in CI, and it really does go GLSL →
SPIR-V → MSL → pipeline. It removes the situation where a broken shader has to be noticed
by looking at the screen.

A chain is checked once too — running slot by slot and running them chained are different
routes.

- [x] `.github/workflows/ci.yml` — push · PR
- [x] Architecture — rather than splitting into two runners, **build universal on one**.
      swiftc cross-compiles to x86_64, so both slices are confirmed to compile, and the
      x86_64 **run time** cannot exercise Metal capture on either an arm64 or an x86_64
      runner, so another runner gains nothing
- [x] `.github/workflows/release.yml` — a pushed `v*` tag runs `release.sh` → draft Release

## 6. Naming and traces

### Ten references to `~/nixos-config`

```
Config.swift           this app assumes it will be managed from ~/nixos-config
LoginItem.swift        three places
Knobs.swift            the convention is what ~/nixos-config/apps/rice-knobs already used
main.swift             two places — when the look was changed with rice-crt…
Control.swift          the switcher (rice-crt) and the slider (rice-knobs) share the hole
ShaderSource.swift
tools/make-signing-cert.sh
README.md              several places
```

**They must not be deleted.** These comments are not decoration but reasoning — why JSON
instead of `UserDefaults`, why launchd instead of `SMAppService`, all hang here, and
without them the code has no answer to "why was it done this way".

**Only the pointers go.** The reasoning is rewritten as sentences that stand on their own:

> ~~`seedMacRice` in `~/nixos-config` shows it — symlinking the store with `home.file`
> makes the target read-only~~
>
> → In an environment that manages configuration declaratively (Nix home-manager and the
> like), a target symlinked from the store is read-only. So…

A sentence that only means something once you open a repo nobody can read is not
reasoning; it is a claim that reasoning exists.

- [x] ten places in source comments
- [x] `README.md` (rewritten during the language work anyway)
- [x] the line in `tools/make-signing-cert.sh` can simply go — it points at the same
      script in another repo, which is useless to anyone else

### The bundle ID stays

`dev.jh.global-shader` is ordinary reverse-DNS and there is no reason to change it.
Changing it would split the granted Screen Recording permission, the `~/.config` path, and
the LaunchAgent label all at once.

But it was **written out separately in four places**:

```
LoginItem.swift    static let label = "dev.jh.global-shader"
Instance.swift     …lock
Control.swift      …sock
main.swift / Menu.swift   the tccutil command inside the hint text
```

They come down to one. Nothing is wrong today, but the day one of the four gets changed
alone gives "the lock is held but the socket is somewhere else", which cannot be found
from the symptom.

- [x] collapse to `Ident.bundleID` and derive the rest from it

## 7. Documentation

- [x] `README.md` → English. The current one to `README.ko.md`
- [x] Then split into `docs/` — architecture · usage · knobs · shaders · performance ·
      permissions · languages · licence, eight topics in two languages. The root README is
      117 lines
- [x] **A screenshot or a 3-second GIF** at the top. For a tool that lays glass over the
      screen, describing it in prose loses on principle. **Only a person can do this** —
      by default the overlay does not appear in screenshots (feedback defence), so it has
      to be launched with `--capturable` and captured. At 117 lines the README now has an
      obvious place for it.
      Landed as two stills and a 48 s demo, each placed beside the sentence it shows
      rather than stacked at the top. They are GitHub attachment URLs, not files in the
      tree: a `--HEAD` install clones this repo, so media committed here would be
      downloaded by everyone who installs
- [x] the install section is currently one `./build.sh` → requirements (macOS 13+,
      glslang, spirv-cross), Screen Recording permission, and that being self-signed it is
      not a distribution
- [x] `CONTRIBUTING.md` — how to add a shader: the two conventions, the `@min..max` knob
      notation, verifying with `--check`, and what does not get in (the "retired" section
      of the docs already states the standard)
- [x] `plan/` is committed. These decisions will want rereading later

## 8. Deferred

| | Why |
|---|---|
| `Package.swift` + `swift test` | The `--check` CI catches most regressions. The one place that genuinely wants unit tests is the GLSL preprocessing parser in `ShaderSource`, and one parser does not justify replacing the whole build system |
| Bundling the tools (C) · static linking (D) | See "It could be removed entirely" above. Without signing, only half of it can be tested |
| Revisiting the `--space-fix` default | That is behaviour, not shape |
| A self-updater such as Sparkle | brew does that job |
