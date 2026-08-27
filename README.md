# global-shader

[![ci](https://github.com/joonhoekim/global-shader-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/joonhoekim/global-shader-for-macos/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Hyprland's `decoration:screen_shader`, for macOS.

Takes the finished screen — one frame, already composited — and runs a fragment
shader over it once more. Wallpaper, menu bar, windows: everything goes behind
the same glass.

It captures the display with ScreenCaptureKit, translates your GLSL to Metal,
and draws the result back over the whole screen. The point is to run `.frag`
files written for a Hyprland session **without changing a character of them** —
the same file keeps working on Linux.

*[한국어 문서](README.ko.md)*

> **There is no download yet.** The app is self-signed, so Gatekeeper blocks it
> on anyone else's machine. Building from source is currently the only way — see
> [`plan/`](plan/README.md) for what a distributable build would take.

## Build

macOS 13 or later, Xcode command line tools, and two shader tools.

```sh
brew install glslang spirv-cross

git clone https://github.com/joonhoekim/global-shader-for-macos
cd global-shader-for-macos
./build.sh
```

With `nix` instead of Homebrew:

```sh
nix shell nixpkgs#glslang nixpkgs#spirv-cross -c ./build.sh
```

`build.sh` is `swiftc` plus a bundle — there is no Xcode project. It generates
two files first (tool paths and version, and the translation table), compiles,
wraps the result in `GlobalShader.app`, and signs it. The bundle matters: macOS
attaches the Screen Recording permission to a code signing identity, so a bare
binary would borrow your terminal's permission instead of holding its own.

The build produces arm64 only. `GS_ARCHS="arm64 x86_64" ./build.sh` makes it
universal, but that has never been run on an Intel Mac — CI only confirms it
compiles.

## First run

```sh
open build/GlobalShader.app
```

macOS asks for Screen Recording permission. Allow it, then look for `◲` in the
menu bar — everything is under there: chain order, knob sliders, profiles,
settings.

If the permission is granted and still nothing happens, you have hit the rebuild
trap: an ad-hoc signature changes on every build and TCC ties the grant to the
old one, so the checkbox stays checked while the app is silently denied.
[How to fix it for good](docs/permissions.md).

## Run it

```sh
./build/global-shader shaders/crt/crt.frag                # apply one
./build/global-shader shaders/water/still.frag shaders/print/paper.frag
                                                          # stack, in order
./build/global-shader --profile golden-era                # a saved set
./build/global-shader --set CURVE 0.22                    # push a value, live
./build/global-shader --check shaders/water/still.frag    # translate only —
                                                          # no window, no permission
```

If one is already running, those change the running instance rather than
starting a second. To stop it: `◲` → Quit, `--stop`, or SIGINT/SIGTERM.

`--help` lists every option. It speaks English or Korean; see
[Languages](docs/i18n.md).

## The shaders

```
shaders/
├── crt/          crt.frag  glow.glsl
├── water/        still.frag  river.frag  ocean.frag
├── cyberpunk/    neon.frag  glitch.frag
└── print/        paper.frag
```

Both the Hyprland and Shadertoy conventions are detected automatically, so files
from either drop in unchanged. A `#define` with an `@min..max` comment becomes a
live slider. What each family is, and why its values are what they are, is in
[The shaders](docs/shaders.md).

## Documentation

| | |
|---|---|
| [Architecture](docs/architecture.md) | Why capturing the screen is the only route that works, the frame path, the one fatal failure, GLSL → MSL, the two shader conventions |
| [Usage](docs/usage.md) | Chains, the menu bar, settings and profiles, start at login, the control socket, every option |
| [Knobs and redraw](docs/knobs.md) | Shader values you can drag while it runs, `!motion`, and how continuous redraw is decided |
| [The shaders](docs/shaders.md) | What each family does and why — including three that were removed |
| [Performance](docs/performance.md) | What it costs, measured, and what has not been measured |
| [Screen Recording permission](docs/permissions.md) | The trap where rebuilding silently revokes it |
| [Languages](docs/i18n.md) | English and Korean, and what is deliberately left untranslated |
| [License and prior art](docs/provenance.md) | Attribution for the shaders, and similar projects |

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers adding a shader, adding a
translation, and what does not get in. [`plan/`](plan/README.md) is the working
list for getting this repo publishable and into Homebrew.

## License

MIT — see [LICENSE](LICENSE). The CRT family is a derivative work and the water
set took one idea from elsewhere; both are credited in
[License and prior art](docs/provenance.md).
