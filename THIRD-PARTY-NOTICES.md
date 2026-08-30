# Third-party notices

This project is MIT licensed — see [LICENSE](LICENSE). This file records the
third-party work it builds on, and the attribution that work is owed.

## Shaders

The CRT shaders — `shaders/crt/crt.frag` and `shaders/crt/glow.glsl` — are
derivative work. The rest of `shaders/` is not; see
[License and prior art](docs/provenance.md).

**Copyright 2023 Maxim Samoliuk — Hyprland screen shader (MIT)**, as shipped in
the "space_dots (Golden Era)" rice (vdawg's chezmoi dotfiles, at
`.other/hyprshaders/orig.frag`). `crt.frag` traces back to it through the
author's ghostty terminal shader; `glow.glsl` in turn derives from `crt.frag`.

What actually survives is the barrel-distortion formula in `curve()` and the
`uv * (1.0 - uv.yx)` vignette idiom, both with changed constants. Bloom
sampling, grain, scanlines, chromatic aberration and edge handling were
rewritten — `crt.frag`'s header records what changed and why — and flicker,
gamut reduction and phosphor tinting were dropped. Both surviving fragments are
common Shadertoy CRT idioms that predate the upstream, so this is likely more
credit than the license strictly requires. It is given anyway, because the path
is real and known.

No canonical URL for the original shader itself was recorded when it was first
adapted; if you know it, a pull request adding it here is welcome.

## Build-time tools

`glslang` and `spirv-cross` are required to build, but are **not** distributed
with this project — they are installed separately through Homebrew or nix, and
`build.sh` only records the paths it found them at.

If they are ever bundled inside the `.app` (branch C in
[`docs/notes/plan/repo-shape.md`](docs/notes/plan/repo-shape.md)), their notices belong in this file:
the licences are `BSD-3-Clause`, `MIT`, and `Apache-2.0`, all of which carry an
attribution obligation. That plan document records why the `GPL-3.0-or-later`
in glslang's licence field does not apply to a bundled build.
