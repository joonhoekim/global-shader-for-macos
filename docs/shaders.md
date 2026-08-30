# The shaders

*[← README](../README.md)  ·  [한국어](shaders.ko.md)*

```
shaders/
├── crt/          crt.frag  glow.glsl          a CRT, and its bloom on its own
├── water/        still.frag  river.frag  ocean.frag
├── cyberpunk/    neon.frag  glitch.frag       written to be stacked
└── print/        paper.frag                   e-ink. free on a still screen
```

The folder is the family name, and the menu bar's `Chain → Add` folds along
exactly these lines. Every file carries its reasoning in its own header — why
each value is what it is — and that same text comes back as slider help
([Knobs](knobs.md)).

Two things are worth knowing before picking one. **Does it read `time`?** If it
does, the screen is redrawn continuously and a laptop pays for it in battery;
`glow.glsl` and `paper.frag` never do, and `crt.frag` stops when its motion knobs
go to 0. And **can you read through it?** That is the bar a shader here has to
clear — [What does not get in](#what-does-not-get-in).

## The CRT family

```sh
global-shader shaders/crt/crt.frag                        # the whole glass
global-shader shaders/crt/glow.glsl                       # the bloom alone
global-shader shaders/crt/crt.frag shaders/crt/glow.glsl  # chained
```

| | |
|---|---|
| `crt.frag` | curvature, aperture grille, scanlines, chromatic aberration, bloom and focus, plus film grain, a mains hum band and click ripples. 30 knobs |
| `glow.glsl` | the phosphor afterglow on its own — no curvature, no aberration, no grille. Never reads `time` |

`crt.frag` reads **outside** its own pixel four ways over (curvature, aberration,
bloom, focus), which is exactly why this program captures the screen instead of
painting on top of it — see the table in [Architecture](architecture.md).

**Everything that flows in it is behind a knob.** Set `GRAIN`, the three `HUM*`
and the three `RIPPLE_*` to 0 and nothing moves — and, because those knobs are
marked `!motion`, continuous redraw switches off with them and the shader becomes
free on a still screen. It was two files once, a still one and a moving one;
[what that cost](notes/history.md#crtfrag-and-crt-motionfrag-merged-into-one) is
in the notes.

`glow.glsl` is the part worth leaving on every day, pulled out as its own file.
It shares `crt.frag`'s origin (both descend from a Hyprland screen shader — see
[License and prior art](provenance.md)) but no code: each is an independent
program, and the bloom is rebuilt the same way in both, a golden-angle spiral
with a soft knee rather than a ring with a hard threshold.

### Turning it off with a knob has to be free

Otherwise the reason to keep a separate still version does not go away. Two
things are involved.

**One. Uniform branches.** A promoted knob is a uniform, so the compiler cannot
fold it — with `GRAIN` at 0 the grain code still runs for every pixel. Wrapping
it in `if (GRAIN > 0.0)` makes it a branch on a single uniform, so the whole warp
takes the same side and it genuinely does not run. Without the wrap, the
difference between a still and a moving CRT (12.1ms → 14.0ms) becomes a permanent
cost. `PRESERVE` in the water set uses the same trick.

**Two. `!motion`.** The automatic redraw judgement reads the source, so at
`GRAIN` 0 it would still see `time` and keep drawing. The marker is how the
shader says otherwise — see [Knobs](knobs.md).

### Why it was not split into a chain instead

Making curvature and the hum band separately applicable was the original idea,
and both are blocked.

- **The hum band and ripples multiply the bloom strength from inside**
  (`humGlow`). Peeled off into a later pass, that pass only sees composited
  colour and cannot touch the bloom term — so "bright things blooming hard as the
  band sweeps past", the part that file records as its most visible feature,
  disappears entirely.
- **Peel off the curvature and the scanlines lose the curved coordinates.** The
  later pass would measure in screen space and the stripes would not bend with
  the glass.

Both are visible regressions, so the axis to split along was knobs, not the
chain.

## The water set

```sh
global-shader shaders/water/still.frag   # a calm surface
global-shader shaders/water/river.frag   # a flowing river
global-shader shaders/water/ocean.frag   # a swelling sea
```

All three are two lines at heart — take the gradient of a height field, and read
`uv` displaced by it. The colour and the glints are decoration on top; **the
displacement is the water.** Which puts these three firmly on the capture side of
the table in [Architecture](architecture.md). Neither a gamma LUT nor a blend
overlay can read `tex`, so on those two routes all that survives is a blue tint.
Same place the curvature in `crt.frag` justified capture.

How the height field is made is what separates the three. The calm surface is
interference of four sines (the gradient comes out analytically, and building it
from noise makes it fizz, which is no longer "calm"); the river is FBM stretched
along the flow axis plus domain warping; the sea is three sine swells with FBM
ripples on top. Details are in each file's header.

Water moves, so all three redraw continuously. **There is no choice there** —
water that does not move is not water — and that is the battery cost this family
has no way around.

### Two new costs a refraction shader pays

**The cursor is offset.** The cursor does not get the shader because the
WindowServer draws it *above* the overlay (see [Performance](performance.md)), and in a
refraction shader that shows up not as latency but as **misalignment** — the
pixel the cursor points at is actually `REFRACT` pixels to one side. `crt.frag`'s
curvature had the same problem, but that one is stationary and water moves.
There is no fixing it from the shader side, so `water/still.frag`, the one meant
to be left on, has a small default `REFRACT` of 1.6 pixels. The 7 pixels in
`water/ocean.frag` are for looking at.

**Text wobbles.** `PRESERVE` is on by default and folds the displacement down
where fine text is dense. [xatuke/screenshader](https://github.com/xatuke/screenshader),
which this drew on, mixes the original colour back into the refracted colour in
its `underwater.frag` — but that strips the water tint only around the text,
leaving rectangular patches. Here it reduces **the displacement itself** rather
than the colour, so the text stands still and the water tint stays even across
the whole screen.

The point is that the fold has to be smooth. Removing displacement only on the
glyph strokes makes the stroke and the counter inside one letter move
differently, which **tears** the letter — worse than wobbling. So it is blurred
over a spiral of taps within a `PRESERVE_PX` radius, and the difference between
taps is measured as an **average**, not a maximum. A maximum saturates on a
single high-contrast edge, which would kill the water on window borders and
wallpaper patterns too.

The cost is 9 texture fetches per pixel (0 when `PRESERVE` is 0 — a branch on a
single uniform, so the whole warp takes the same side).

### Edges

The sampler is `clampToEdge` (`Sources/Renderer.swift`), so a displaced `uv` that
leaves the screen smears the border row. Folding the displacement to 0 across an
`EDGE_FADE` band prevents that. Colour and glints are not folded — they do not
read outside, so there is no reason to, and folding them would make only the
border stop looking like water.

## The cyberpunk set — made to be stacked

```sh
global-shader shaders/cyberpunk/neon.frag                                    just the signage
global-shader shaders/crt/crt.frag shaders/cyberpunk/neon.frag               neon on a CRT
global-shader shaders/cyberpunk/neon.frag shaders/cyberpunk/glitch.frag      the signage skips
```

| | |
|---|---|
| `neon.frag` | a halo picked by **saturation**, not brightness |
| `glitch.frag` | occasional bursts of band displacement, RGB separation, tearing |

**Both stand on their own, but this family was written from the start assuming
it would be stacked.** Before chains existed they would have had to be one file,
and merged you cannot turn just the signage off or try a different order (see
[Chains](usage.md#chains--several-shaders-in-order)).

That assumption pays for itself in two places.

**One. `neon.frag` has no flicker.** Signage feels like it ought to flicker, but
reading `time` even once turns redraw on, and the whole chain pays for that. A
file meant to be stacked cannot make that decision alone — applied after
`crt.frag`, it must not throw away the free-on-a-still-screen property that file
worked to keep. If you want flicker, append `glitch.frag`, and then the decision
to pay for it is already contained in the act of choosing that file.

**Two. `glitch.frag` goes last.** It treats whatever the earlier passes made as a
signal and damages it, so anything after it would be smoothing damage back out.

### Picked by saturation, not brightness

`neon.frag` is that one line. The bloom in `crt.frag` picked by luminance and
that was right — what blooms on a CRT is where the phosphor burned bright. Neon
is different. A white window and white text are not signage no matter how bright;
what burns is a deep colour on a dark ground — a prompt colour, a syntax
highlight, the primary in an icon.

Saturation must not be measured as HSV `S` (= `(mx-mn)/mx`). That explodes on
dark colours — something almost black like `(0.02, 0, 0)` has `S` of 1, so every
speck of noise in a dark theme's background becomes signage. Measuring `mx-mn`
gives you "how deep is this colour" directly.

### Most of the time, nothing should happen

The only hard decision in `glitch.frag`. A screen that crackles continuously is
unusable after thirty seconds. What stays with you is the one burst in an
otherwise clean picture, so time is cut into ticks and a die is rolled per tick:

```
tick = floor(time * RATE)      which tick this is
hash(tick) > 1 - DENSITY       does this tick burst      ← step, not smoothstep
fract(time * RATE)             how far into the tick     → decay
```

Because it is `step`, **0 is really 0.** With `smoothstep`, "ticks that almost
did not burst" apply very faintly all the time, and you are back to a permanent
crackle. This is exactly where it diverges from shaking the strength with a sine
or noise.

The displacement is also the opposite of the water set. There, displaced `uv` was
folded at the edges (clampToEdge); here it **wraps** with `fract()` — a displaced
band continuing out of the other side is what the effect *is*, and folding it
would make the displacement vanish at both screen edges, which looks faker.

## Print — the look that costs zero on a still screen

```sh
global-shader shaders/print/paper.frag                                   e-ink
global-shader shaders/print/paper.frag shaders/cyberpunk/glitch.frag     the print breaks up
```

| | |
|---|---|
| `paper.frag` | e-ink. Applied in order to **read** |

**It never uses `time` once.** So redraw turns off and it uses no GPU on a still
screen. Exactly the opposite axis from the water set, and the battery cost that
one has no choice but to pay is not paid here.

That is chosen, not accidental. Print does not move — the paper grain and the ink
bleed are fixed at the moment of printing and stay that way, so there was never a
place for time to enter. If a rice needs one look that costs zero, this is the
right one.

### A shader applied in order to read

`paper.frag` is applied **in order to read text**, and so every other decision
leans toward legibility. That difference comes out as `SHARP`. Most shaders in
this repo move toward blur (bloom, focus, haze); this one alone **sharpens.**
Bleaching and tonal compression make strokes look soft, so without pulling them
back with an unsharp pass you get a faded screen rather than paper.

## What does not get in

A shader that cannot be *read* through has to be worth it. Three were removed for
failing that — `rain.frag`, `riso.frag` and `dither.frag`, all of which make body
text unreadable — and that is where the bar came from:
[Three shaders that were removed](notes/history.md#three-shaders-that-were-removed).
[`CONTRIBUTING.md`](../CONTRIBUTING.md) states it as the rule for a new one.
