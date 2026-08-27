# Contributing

## Building

```sh
brew install glslang spirv-cross     # or: nix shell nixpkgs#glslang nixpkgs#spirv-cross
./build.sh
```

`build.sh` generates two files before it compiles — `Sources/Generated.swift`
(tool paths, version) and `Sources/Strings.swift` (the translation table). Both
are gitignored. Do not edit them; edit `VERSION` and `i18n/*.json` instead.

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

## Before opening a PR

```sh
./build.sh
for f in shaders/*/*.frag shaders/*/*.glsl; do ./build/global-shader --check "$f" || echo "FAIL $f"; done
./build/global-shader --lang en --help >/dev/null
./build/global-shader --lang ko --help >/dev/null
```

If you touched anything user-visible, check both languages actually render.
