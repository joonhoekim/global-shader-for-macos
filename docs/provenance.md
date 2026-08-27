# License and prior art

*[← README](../README.md)  ·  [한국어](provenance.ko.md)*

## License and provenance

MIT. See [LICENSE](../LICENSE).

`shaders/` falls into two groups.

**Newly written** — the water three (`water/*.frag`), the cyberpunk two
(`neon.frag`, `glitch.frag`), and the print one (`paper.frag`). These share no
code with the CRT family below.

Those six are independent implementations of well-known techniques —
golden-angle spiral bloom, value noise and its analytic derivative, and the like,
are common property of graphics rather than any particular work, and where the
origin matters it is recorded in the file header. No code was copied. (The
removed `rain.frag`, `riso.frag` and `dither.frag` sat in the same group —
Bayer-ordered dithering and rotated CMYK halftones were theirs.)

One thing is called out separately. The **text protection** in the water set took
its idea from `underwater.frag` in
[xatuke/screenshader](https://github.com/xatuke/screenshader) (MIT) — that is
where the problem itself, "what should full-screen water do about text", came
into view. The method is different (see [The water set](shaders.md)) and no formula was
carried over.

**The CRT family (`crt.frag`, `glow.glsl`) is a derivative work.** Its root is
**Maxim Samoliuk's Hyprland screen shader (MIT)** (Copyright 2023), which
shipped in the space_dots (Golden Era) rice — vdawg's chezmoi dotfiles, at
`.other/hyprshaders/orig.frag`.

What actually survives a line-by-line comparison is two things: the
barrel-distortion formula in `curve()` (written per-component upstream, folded
into a vector here, `1/8` → `0.10`) and the `uv * (1.0 - uv.yx)` vignette idiom
in `bezel()` (same expression, different constants). Everything else was
rewritten — bloom (a uniform polar double loop with no threshold became a
16-tap golden-angle spiral with Gaussian weights and a soft-knee luminance cut),
grain, scanlines, chromatic aberration, the aperture grille, the hash function —
and upstream's flicker, gamut reduction and phosphor tinting were dropped
outright. `glow.glsl` shares no line at all with the original; it descends
through `crt.frag`. What changed and why is in the `crt.frag` header.

Both surviving fragments are common Shadertoy CRT idioms that predate the
upstream, so this is likely more credit than the license strictly requires. It
is given anyway, because the path is real and known — this was not an
independent reinvention. No canonical URL for the shader itself was recorded
when it was first brought over, so it is credited by name.

## Prior art

Things using the same structure already exist —
[xatuke/screenshader](https://github.com/xatuke/screenshader) (Swift + SCK +
Metal, automatic GLSL→MSL conversion) and
[RetroVisor](https://dirkwhoffmann.github.io/RetroVisor/) (one movable window
rather than the whole screen). This repo exists separately in order to take the
Hyprland convention as-is (down to `pointer_pressed_*`) so that the same `.frag`
file works on both operating systems.
