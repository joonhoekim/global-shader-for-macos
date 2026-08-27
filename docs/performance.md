# Performance

*[← README](../README.md)  ·  [한국어](performance.ko.md)*

## What it costs

Measured on a MacBook Air M2 (8-core GPU), built-in panel, 2940x1912 backing,
60Hz panel. `--redraw always --no-vsync --fps 1000`, 12 seconds each, 8 seconds
of cooldown between runs.

| | fps | per frame |
|---|---|---|
| passthrough (no shader) | 143.4 | 7.0ms |
| `crt.frag` | 82.6 | 12.1ms |
| `crt.frag` (knobs promoted) | 83.4 | 12.0ms |
| `crt.frag --scale 0.7` | 122.6 | 8.2ms |
| `crt-motion.frag` (now merged into `crt.frag`) | 71.5 | 14.0ms |
| merged `crt.frag`, motion knobs at 0 | **not measured** | should come back to the 12.1ms above |
| `water-*.frag`, the cyberpunk set, the print set | **not measured** | |

**All of them fit inside 60fps (16.7ms).** With vsync on, all five configurations
sit at 58–59fps, so there is no reason to lower `--scale` on this machine. It is
the knob for when a bigger display or a heavier shader runs short.

**Knob promotion is free** (82.6 → 83.4, within noise). This shader is bound by
roughly twenty texture fetches per pixel, so the constant folding lost when a
constant becomes a uniform never surfaces. That number is the basis for having it
on by default.

Note that even the passthrough costs 7ms. That is the floor for capture and
present, not the shader, so no amount of shader work goes below it.

`--scale` blurs the screen because of the backing resolution. In a "more space"
style scaled mode, macOS draws the desktop at 2940x1912 and downscales to the
2560x1664 panel. Our layer is composited into that same 2940 buffer, so 2940 is
the default. Drawing at panel size would mean upscaling and then downscaling —
blurrier, not sharper.

### Everything else

- **Latency** — because it films and then draws, the screen is about one frame
  behind. The overlay covers the screen completely so nothing appears doubled;
  everything is late by the same amount. Dragging a window shows it best.
- **Cursor** — not filmed (`showsCursor = false`). The real cursor, which the
  WindowServer draws **above** the overlay, stays as it is. The cursor is the one
  thing that does not get the shader, and in exchange it has zero latency.
  Putting the cursor behind the glass would make it the one place where the
  latency is visible.
- **Screen Recording permission** — asked for on first run. System Settings →
  Privacy & Security → Screen Recording. This is why `build.sh` wraps it in a
  `.app` and signs it. Running the inner binary alone attaches the permission to
  the terminal instead. **There is a trap where rebuilding silently cuts it off**
  — see [Screen Recording permission](permissions.md).
- **Protected video (DRM)** — SCK excludes protected windows from capture. That
  region is expected to come out black, but **this has not been confirmed.**
- **Screenshots** — the shader does not appear in them by default (see
  [Feedback](architecture.md)).
- **Battery and heat** — continuous redraw uses the GPU at the refresh rate even
  on a still screen. This is exactly the fork Hyprland's `debug:vfr` presents, and
  here `--redraw auto` (the default) decides it. See [Knobs](knobs.md). The cost
  scales with pixels × frames, so a larger or faster display pays more of it before
  any shader runs — and on a laptop it comes out as warmth as much as battery.
  **Power draw and temperature have not been measured**, only per-frame cost.
- **Refresh rate** — read from `NSScreen.maximumFramesPerSecond`.
  `CGDisplayMode.refreshRate` is known to return 0 on built-in ProMotion panels,
  which would cut 120Hz down to 60. That fork does not show up on a 60Hz machine,
  so it is **unverified on ProMotion.**

## Not done yet

- The intermediate targets in a chain are `bgra8Unorm`. That was chosen so values
  mean the same thing as in a single pass (down to being clipped at 8 bits), but
  stacking three or four contrast-raising shaders could show banding. **Not
  measured stacked.**
- Chain performance is not measured either. Every row in the table above is a
  single shader.
- **The cost table is from a machine this is no longer developed on.** It was taken
  on a MacBook Air M2 with its built-in 60Hz panel; the current machine is an M4 Pro
  driving one larger external display in clamshell. Nothing has been re-measured
  there, and the two differences pull in opposite directions — a faster GPU makes
  each frame cheaper, more pixels make it dearer. Treat every number above as
  belonging to the machine named beside it.
- Multiple displays are supported in code but **only verified on one.** Clamshell
  with a single external display is still one display, so that has not changed.
- The deployment target is macOS 13.0. It was 14.0 for no reason; 13.0 builds
  without a single warning, and 12.3 is blocked by exactly one line
  (`cfg.capturesAudio = false`, which only states the default). **Only 15 has
  actually been run** — 13 and 14 are verified to compile, nothing more.
- How it looks over another app's full screen, and in Mission Control, is
  unverified. That is why `--space-fix` defaults to `off` — Space-switch ghosting
  has not been observed on this machine, and there is no reason to pay for an
  unseen problem by default. If you see it, start with `freeze` (hold the last
  frame); if that still looks wrong, `hide` (hide the window briefly — you see
  the unshaded screen during that time).
- The cost of the three `water-*.frag` is not measured; the table above just has
  the row reserved. The noise is ALU-bound and there are 10 texture fetches
  including `PRESERVE`, against roughly 20 in `crt.frag`, so it should be
  cheaper — but **that is an estimate, not a measurement.**
- The cyberpunk and print sets are not measured either. The 20 taps in
  `neon.frag` are almost certainly heavier than the bloom in `crt.frag` (16
  taps), and the print set has only one or two fetches so it should be much
  cheaper. Both are estimates.
- None of the six has been **put on a real screen and tuned by eye.** Only
  translation and knob promotion were confirmed with `--check`. The values were
  chosen to make sense in place, so there is still room to turn the knobs against
  an actual screen.
- Whether the merged `crt.frag` with the motion knobs at 0 **produces the same
  picture as the old `crt.frag` has not been compared by eye.** In code the same
  expressions sit in the same places and `modulate(col, 0, …)` is the identity,
  but that is knowing by reading, not by looking.
- **Whether the uniform branches actually save anything is not measured.** It
  rests on the whole warp taking the same side; the check is whether the "motion
  knobs at 0" row in the cost table comes back to 12.1ms.
- Latency has not been measured in seconds.
- Detection of a declaratively-managed agent is written, but **not verified with
  one actually installed that way.** What has been verified is only the app
  turning it on and off itself.
