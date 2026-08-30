# Contributing

## Building

```sh
brew install glslang spirv-cross     # or: nix shell nixpkgs#glslang nixpkgs#spirv-cross
./build.sh
```

`build.sh` generates two files before it compiles — `Sources/Generated.swift`
(tool paths, version) and `Sources/Strings.swift` (the translation table). Both
are gitignored. Do not edit them; edit `VERSION` and `i18n/*.json` instead.

## The icon

`Resources/icon.png` is the master — one 1024×1024 full-bleed square — and
[`tools/make-icon.swift`](tools/make-icon.swift) masks it into the macOS icon
shape at each of the ten `.icns` slots. To change the icon, replace that one
file; to change the shape, the margin or the shadow, that script's header
explains where every number came from.

The result is cached at `build/AppIcon.icns` and recomposed only when the
artwork or the script is newer, so it stays out of the shader edit / rebuild
loop. Delete it to force a rebuild.

`LSUIElement` keeps this app out of the Dock, so the icon is not for the Dock.
Where it does show is Finder, Spotlight, Login Items, and the list in System
Settings → Privacy & Security → Screen Recording — that last one being the
place a user has to pick this app out by sight.

The fastest check for anything shader-related needs no permission and no window:

```sh
./build/global-shader --check shaders/crt/crt.frag
./build/global-shader --check shaders/crt/crt.frag shaders/crt/glow.glsl   # as a chain
```

CI runs exactly that over every shader in the repo.

## Adding a shader

Drop a `.frag` in the right family folder under `shaders/`. The folder is the
family name and the menu folds along the same lines.

**Two conventions are detected automatically.** If the file contains
`mainImage(` it is treated as Shadertoy, otherwise as Hyprland. Both are
described in [Architecture](docs/architecture.md). A file written for a Hyprland
session works unchanged —
that is the point of this repo, so please keep it that way.

**Declare your knobs.** A `#define` with an `@min..max` comment is promoted to a
uniform and gets a live slider:

```glsl
#define CURVE   0.10   // @0..0.3
#define BLOOM   0.32   // @0..1:0.01     (trailing step is optional)
#define GRAIN   0.03   // @0..0.15 !motion
#define TAPS    16                       ← unmarked: not a knob
```

Only mark values that are meant to be dragged. Things that must stay constants
(array sizes) and things that are not scalars (`vec3`) are filtered out anyway,
but marking them just produces a shader whose promotion folds.

`!motion` means "when this value is 0, the motion this knob is responsible for
stops". When every marked knob is 0, the app turns off continuous redraw and the
shader becomes free on a still screen. If your shader reads `time`, marking the
knobs that gate that motion is the difference between a look someone can leave on
and one they cannot.

**Wrap expensive optional work in a uniform branch.** A promoted knob is a
uniform, so the compiler cannot fold it away — `if (GRAIN > 0.0) { … }` is what
actually makes turning it off free.

**Write down why each value is what it is.** The comment block directly above a
`#define` is returned as `doc` and shown as slider help. The shaders in this repo
carry their reasoning; that is a large part of what they are for.

### What does not get in

Three shaders were removed after living with them: `rain.frag`, `riso.frag` and
`dither.frag`. The criterion was not that they looked bad — it was that all three
made body text unreadable, and the look was not worth that.
[The shaders](docs/shaders.md) records this in detail.

So: a shader that cannot be *read* through has to be worth it. Something meant
for looking at rather than working under is fine, but say so in the header, and
expect the default values to be pushed toward the readable end.

## Adding or changing a translation

```
i18n/
  en.json    the base — it defines the key set
  ko.json    a translation
```

Adding a language is one file: copy the key set from `en.json` and translate the
values. `build.sh` will refuse to build until every key is present.

```json
"menu.chain.moveUp": { "en": "Move up" },
"knob.err.noPass":   { "args": ["Int", "Int"],
                       "en": "no pass %1$d in the chain (%2$d now)",
                       "note": "shown when a chain index is out of range" }
```

- Placeholders **must** be positional (`%1$@`, `%2$d`). Word order differs per
  language and a bare `%@` cannot be reordered.
- `args` may be `String`, `Int` or `Double`.
- `note` is for translators; it ends up as a doc comment in the generated file.
- Long blocks (like `--help`) are one key, not one key per line, so that a
  translator can align the columns for their own language.

**Do not add keys for the control socket.** Everything spoken over the socket is
English on purpose — it is read by programs, and an answer that changes with a
language setting breaks anything that branches on it.

Knob `doc` text is likewise not translated, but for a different reason — see
[Languages](docs/i18n.md). Short version: it lives inside shader headers that
argue at length about each value, and keeping two of those in step is not worth
a slider tooltip.

## Code

- Comments in this repo explain **why**, not what, and they are load-bearing.
  If you change a decision, change the comment that justified it.
- Everything in the source — comments, scripts, shader headers, translator notes
  in `i18n/en.json` — is English. The Korean lives where it is read as Korean:
  `i18n/ko.json` and the `*.ko.md` documents.
- No Xcode project. `build.sh` is `swiftc` plus a bundle, and keeping it that
  simple is deliberate.

## The formula

CI's second job installs `Formula/global-shader.rb` the way somebody else would:
a throwaway tap, a tarball of the checkout, and Homebrew's own sandbox. That is
the only place the parts a formula adds get exercised — the baked `opt/` tool
paths, the `.app` landing in the prefix, the `bin` symlink, `brew test` — and
none of them are visible from `./build.sh` passing. Locally:

```sh
# The formula file on its own. No tap needed, and this is the file that gets
# committed. (CI runs `brew style gs-ci/local`, over the whole tap, which also
# lints the workflow files `tap-new` generates. That needs actionlint, and
# actionlint reads its config out of Homebrew's own repository — free on a
# runner, out of reach under nix-homebrew, which stubs that repository out.)
brew style Formula/global-shader.rb

brew tap-new gs-ci/local --no-git
cp Formula/global-shader.rb "$(brew --repo gs-ci/local)/Formula/"
brew trust --formula gs-ci/local/global-shader

# The committed formula is head-only, and a head build clones main — which is not
# the code you are testing. Point a copy at a tarball of this checkout instead.
v="$(tr -d '[:space:]' < VERSION)"
ref="$(git stash create)"                       # empty on a clean tree
git archive --format=tar.gz --prefix="global-shader-$v/" \
            -o "/tmp/global-shader-$v.tar.gz" "${ref:-HEAD}"
./tools/update-formula.sh "file:///tmp/global-shader-$v.tar.gz" \
                          "$(brew --repo gs-ci/local)/Formula/global-shader.rb"

brew install --build-from-source gs-ci/local/global-shader
brew test gs-ci/local/global-shader
brew uninstall global-shader && brew untap gs-ci/local
```

The tarball's file name is not decoration: Homebrew reads the version out of it
and rejects a tarball it cannot read one from.

### If nix owns your Homebrew

`brew style` and `brew test` load Homebrew's vendored gems, which means writing
inside Homebrew's own checkout. Under nix-homebrew that checkout is a
`/nix/store` symlink, so both fail and the formula half of CI cannot be run at
all. Put [`tools/brew-nix.sh`](tools/brew-nix.sh) in front of `brew` for those
commands — it mirrors the library somewhere writable and leaves the prefix, the
Cellar and your taps exactly as they are:

```sh
./tools/brew-nix.sh style Formula/global-shader.rb
./tools/brew-nix.sh test gs-ci/local/global-shader

shim="$(./tools/brew-nix.sh)"     # or take the path once and use it as brew
```

The first run mirrors and bundles, about twenty seconds; after that it is as
fast as `brew`. `brew install` needs none of this — it only writes to the
Cellar. Styling a whole tap stays out of reach even with the shim. That script's
header explains all three, including the one the error message never mentions.

## Before opening a PR

```sh
./build.sh
for f in shaders/*/*.frag shaders/*/*.glsl; do ./build/global-shader --check "$f" || echo "FAIL $f"; done
./build/global-shader --lang en --help >/dev/null
./build/global-shader --lang ko --help >/dev/null
```

If you touched anything user-visible, check both languages actually render.
If you touched `Formula/global-shader.rb`, `build.sh` or anything the formula
installs, run the formula job above too — `./build.sh` passing says nothing
about it.
