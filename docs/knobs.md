# Knobs and redraw

*[← README](../README.md)  ·  [한국어](knobs.ko.md)*

## Knobs — shader values, live

A `#define` with an `@min..max` comment is promoted to a uniform **by default**.
Then a value can be pushed over the socket with no re-translation and no
recompilation.

```sh
global-shader shaders/crt/crt.frag &
global-shader --set CURVE 0.22      # takes effect next frame
global-shader --get                 # all of them, as JSON
global-shader --reset CURVE         # back to the file's value
```

The same thing is in the menu bar under `Knobs`, as sliders. You do not pick a
shader value by knowing the number — you watch the screen and stop, so the
shorter round trip wins. When a step is declared, as in `@0..1:0.01`, the slider
only lands on those stops — that is the author's judgement that "finer than this
is not visible", used as-is.

### The slider that did nothing on a still screen

A shader with redraw off (one that does not read time, like `crt.frag`) only
gets frames when something on screen changes. Change a value in that state and
**nothing happens** — the value changed, but there is no occasion to draw. To a
person that is indistinguishable from a broken slider. So a value change now
pushes the last frame through once more.

### In a chain, names are prefixed with the pass number

Stack two shaders and the names collide. `crt.frag` and `glow.glsl` both declare
`BLOOM`, `SCAN_PX` and `BRIGHTNESS` — which is not strange but expected, since
each was written assuming it would be applied alone. One value per name would
mean one slider pushing both shaders, and that is the kind of confusion you
cannot fix afterwards.

```sh
global-shader --set 2.BLOOM 0.9     # BLOOM in pass 2 (glow.glsl)
global-shader --set CURVE 0.24      # unique names work bare
global-shader --set BLOOM 0.9
  err ambiguous name — prefix it with the pass number: 1.BLOOM (crt.frag), 2.BLOOM (glow.glsl)
```

`--get` keeps the existing `name`, `value`, `min` and `max` and **adds**
`id` ("2.BLOOM"), `pass` and `shader`. Anything that only read the old fields
keeps working unchanged.

The convention is not this repo's invention. It is the notation the author was
already using to push shader values live on Linux, brought over as-is. **Not a
character of the shader files changes** — on Linux they stay plain `#define`s.
For `crt.frag` that is 30 knobs:

```
CURVE VIGNETTE FOCUS FOCUS_NEAR FOCUS_RADIUS ABERRATION
BLOOM BLOOM_PX BLOOM_CUT BLOOM_KNEE BLOOM_KEEP
SCAN_PX SCAN_DEPTH GRILLE CONTRAST BRIGHTNESS
ANIM_SPEED GRAIN GRAIN_HZ
HUM HUM_LIFT HUM_GLOW HUM_WIDTH HUM_SPEED
RIPPLE_SEC RIPPLE_MAX RIPPLE_W RIPPLE_GAIN RIPPLE_LIFT RIPPLE_GLOW
```

The unmarked ones — `TAU` `EDGE_SOFT` `BLOOM_TAPS` `GRILLE_PX` `GRAIN_PX`
`GRAIN_ADD` `GRAIN_MUL` `RIPPLE_TAPS` `TINT` — are left alone. Things that must
be constants (`BLOOM_TAPS`) and things that are `vec3` (`TINT`) filter
themselves out, because the author only ever put `@` on values meant for a
slider.

### Shaders that cannot be promoted fold on their own

Promotion turns a constant into a uniform, so if that value is used somewhere it
**has to be** a constant, the whole compilation fails:

```glsl
#define TAPS 8   // @1..16
float w[TAPS];   → ERROR: array size must be a constant integer expression
```

When that happens it translates once more without promotion and applies that.
The shader runs exactly as before, minus the knobs. This fallback is why
promotion can be the default without regressions — without it, a shader that
worked yesterday would drop to a passthrough today.

`--check` says when it folded, and `--set` returns the reason rather than
pretending to succeed. To turn it off for real: `--no-knobs`.

`--get` also reports whether `!motion` was attached, as `motion`, so the UI can
tell whether turning a slider down saves battery.

`--get` also returns the **comment block sitting directly above the `#define`**
as `doc`. The shaders in this repo already record why each value is what it is,
so there is nothing separate to write for slider help.

### Why this did not work on Hyprland

The list of uniforms a Hyprland screen shader receives is decided by the
compositor, and ours cannot be added to it. So changing a value meant rewriting
the `#define` and re-applying the shader — and while dragging a slider that
round trip happens several times a second, which forced the caller to debounce.

**That constraint is Hyprland's, not macOS's.** Here we decide the uniform list.
No file rewriting, no re-translation, no debounce.

## The shader decides whether to keep drawing

If a shader reads time, it has to keep drawing even when the screen does not
change, or nothing flows. If it does not, not drawing is correct. That judgement
is `--redraw auto` (the default), on the same criterion that decided whether to
turn `debug:vfr` off on Hyprland.

```
crt/crt.frag           on     set to 0 to stop: GRAIN HUM* RIPPLE_GAIN/LIFT/GLOW
crt/glow.glsl          off
water/still.frag       on     set to 0 to stop: SPEED CLICK
water/river.frag       on     set to 0 to stop: FLOW
water/ocean.frag       on     set to 0 to stop: SPEED
cyberpunk/neon.frag    off
cyberpunk/glitch.frag  on     set to 0 to stop: DENSITY
print/paper.frag       off
```

The right-hand column is `!motion`, below. **The four that are off never read
`time` in the first place**, and the ones that are on become off on the spot when
the listed knobs go to 0.

All three water shaders come out on. **There is no choice there** — water that
does not move is not water. `crt.frag` being free on a still screen was because
that shader had nothing flowing in it, not because the automatic judgement did
something clever.

**In a chain, one link being on makes the whole thing on.** A link that reads
time and does not flow does not look like one stopped pass, it looks broken. So
this judgement becomes a **file-selection decision** when stacking:

```
crt/glow.glsl → cyberpunk/neon.frag         [redraw off]   free on a still screen
crt/glow.glsl → neon.frag → glitch.frag     [redraw on]    you get flicker and you pay for it
```

This table is why `neon.frag` has no flicker in it (see that file's header). With
flicker, the first line above would not exist.

**Stripping comments first is the crux.** The shaders in this repo write at
length about why each value is what it is, and mention `time` often inside those
comments:

```
glow.glsl   '\btime\b'  2 with comments → 0 in code alone
crt.frag    '\btime\b'  10 with comments → 2 in code alone
```

Without stripping, `glow.glsl` is misjudged and burns battery on a still screen
with nothing flowing in it at all. With stripping, it separates cleanly, 0 against 2.

Misjudgement errs on the safe side — being wrong costs battery, it does not
freeze the screen. Saving an edited shader re-runs the judgement.
`--redraw always` / `never` overrides it.

## Knobs open and close time — `!motion`

**"Reads time" and "is flowing right now" are different things.** The judgement
above only sees the source, so it cannot tell them apart. That never mattered
while the flowing and non-flowing variants were two separate files — which is
what `crt.frag` and `crt-motion.frag` were.

Merging those two into one file ([The shaders](shaders.md)) made the judgement
insufficient.
The merged file still has `time` in its source with grain at 0, so it would
always be on, which makes **the merge itself a regression** — you can turn it off
with a knob, but the battery keeps draining.

So the shader declares it. Putting `!motion` next to an `@range` means "when this
value is 0, the motion this knob is responsible for stops", and **when every
marked knob is 0, redraw turns off.**

```glsl
#define GRAIN     0.030   // @0..0.15 !motion
#define HUM       0.04    // @0..0.3 !motion  how much brighter bright pixels get inside the band
#define GRAIN_HZ  40.0    // @5..60           ← unmarked. a speed, not a switch
```

```sh
global-shader --set GRAIN 0     # stops drawing on a still screen from this moment
global-shader --set GRAIN 0.03  # comes back on with it
```

The judgement re-runs on every value change. Reading the markers only once at
first translation would mean the battery keeps draining after you pull the slider
down — the kind of fault that is invisible on screen.

What was actually confirmed to differ:

```
crt.frag defaults                     redraw = true
crt.frag all motion knobs at 0        redraw = false
crt.frag GRAIN brought back           redraw = true
water/still.frag defaults             redraw = true
print/riso.frag (does not read time)  redraw = false
crt.frag(0) → water/still.frag        redraw = true    ← the later pass flows
crt.frag(0) → print/riso.frag         redraw = false
```

(A shader with no declarations is judged from source as before. When this was
checked, `still.frag` had no markers yet; now they are on `SPEED` and `CLICK`.
`riso.frag` was removed afterwards — this table is **what was actually measured
at the time**, so the names have not been rewritten. To check the same thing
today, `print/paper.frag` stands in. It does not read `time` either.)

`--status` returns `redraw` and `redrawMode`. **You cannot read this off fps** —
frames arrive whenever the screen changes even with redraw off, and `fps` is the
average since launch, so something that just turned off does not show up.
`--check` also tells you which knobs to set to 0 to turn it off.

### The ones that are deliberately unmarked

`ANIM_SPEED` has no marker. At 0 the grain pattern and the hum band are still
right there (stopped, not gone), and click ripples run on real seconds so they
keep moving — it is not a condition for "nothing is moving".

Conversely, if `GRAIN` is non-zero while `ANIM_SPEED` is 0, nothing actually
moves but it is judged on. The misjudgement errs on the safe side, so it stays.

### Shaders whose promotion folded

The markers cannot be read, so it falls back to judging from source as before.
That is correct — without promotion the values are whatever constants the file
holds, so we know nothing, and when we know nothing, on is the safe side.

### On Linux

`!motion` is just a comment. Hyprland requires `debug:vfr = false` for shaders
that use `time`, so VFR has to stay off regardless of a value being 0. That is
the compositor's judgement, not something a shader can affect.
**Still not a character changed in the file.**
