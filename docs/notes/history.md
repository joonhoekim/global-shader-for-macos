# What was removed, and what changed

*[← README](../../README.md)  ·  [한국어](history.ko.md)*

Decisions that are already carried out. None of it is needed to use the app — it
is here so that the reasoning survives the change, and so the pages you actually
read while using it stay about what is there now.

- [Three shaders that were removed](#three-shaders-that-were-removed)
- [`crt.frag` and `crt-motion.frag`, merged into one](#crtfrag-and-crt-motionfrag-merged-into-one)
- [The menu was buried under the glass](#the-menu-was-buried-under-the-glass)
- [What was measured when `!motion` landed](#what-was-measured-when-motion-landed)
- [The screen that woke up frozen](#the-screen-that-woke-up-frozen)

The pre-release checklist this repo was made public from is beside this file, in
[`plan/`](plan/README.md).

## Three shaders that were removed

There used to be three more: `cyberpunk/rain.frag` (raindrops),
`print/riso.frag` (risograph halftone) and `print/dither.frag` (four-colour Game
Boy). They were removed after actually living with them in a Linux Hyprland
session — all three make body text unreadable, and the look was not worth that
price. It is not that they were beyond saving. `rain.frag` could have borrowed
`busy()` from its sibling `water/still.frag` to fold refraction down over fields
of text, and `dither.frag` improved when `PIXEL` came down. But none of the
three becomes a look you can *read* through. `dither.frag` cannot, in principle:
protecting letterforms means not pixelating, and then it is no longer that
shader.

That criterion is what [`CONTRIBUTING.md`](../../CONTRIBUTING.md) records as the
bar for a new shader. The print family is the clearest case of it: `riso.frag` and
`dither.frag` traded legibility for a look, and the one of the three that survived
is the only one made **in order to read** — which is not a coincidence.

Removing them is also what settled the folder layout. The folder is the family
name, and the menu bar's `Chain → Add` folds along exactly these lines. Laying
everything out flat was right at three or four files; at twelve it stopped being
right — a list you have to read name by name to understand is not a list.

## `crt.frag` and `crt-motion.frag`, merged into one

There used to be two CRT files: the version with the flowing parts (grain, hum
band, click ripples) and the version without. The reason for the split was the
redraw judgement — a shader that reads `time` has to keep drawing, so the still
version existed to stay free on a still screen ([Knobs](../knobs.md)).

**It is less that the judgement was wrong than that what it promised was not
kept.** Before merging, the two were compared:

```
curve · gun · focusAt · bloom · stripes · bezel   0 lines of difference in code, comments aside
#define present only in crt.frag                  none (motion was a superset)
FOCUS                                             0.18  vs  0.32   ← diverged
FOCUS_NEAR                                        0.25  vs  0.28   ← diverged
```

The header of `crt-motion.frag` said "if you change this, change `./crt.frag`
too". Those two lines are what writing that down amounts to. The failure
duplication invites was not "these could diverge some day" — it had already
happened.

The two divergences were resolved toward `crt.frag` (0.18 / 0.25), because that
file's comments record why it came down from 0.5 to there, and the 0.32 on the
motion side was a copy made before that judgement landed. They are knobs, so you
can put them back by eye.

To get the old still `crt.frag` exactly:

```sh
global-shader --set GRAIN 0
global-shader --set HUM 0 && global-shader --set HUM_LIFT 0 && global-shader --set HUM_GLOW 0
global-shader --set RIPPLE_GAIN 0 && global-shader --set RIPPLE_LIFT 0 && global-shader --set RIPPLE_GLOW 0
```

The merge is what forced `!motion` into existence. Judging redraw from the source
alone, the merged file reads `time` even with the grain at 0, so it would always
be on — which would have made **the merge itself a regression**: you could turn
the motion off with a knob and the battery would keep draining. The declaration,
and how it is re-judged on every value change, is in [Knobs](../knobs.md).

The two properties that had to hold for the merge to be free — a uniform branch
around the expensive optional work, and `!motion` on the knobs that gate it — are
in [The shaders](../shaders.md#turning-it-off-with-a-knob-has-to-be-free).

## The menu was buried under the glass

**This is a fixed bug, and nobody knew about it before the menu bar UI existed.**

The overlay lives at `CGShieldingWindowLevel()`, which is 2147483628. A menu's
dropdown window is 101 (`kCGPopUpMenuWindowLevel`), and `NSAlert` and
`NSOpenPanel` are 8. Which means **the menu you get by clicking the status item
is buried under the overlay.** Cover the screen in red, open the menu, take a
screenshot: not one pixel of the menu is visible.

The `◲` in the menu bar was visible all along, but only because the menu bar is
owned by the WindowServer and therefore **appears in the capture** — it was
showing through the glass. The dropdown is owned by our app, so it is excluded
from the capture (per-app exclusion) and it is below in level too: neither
visible nor showing through. With four items you could click from memory. The
moment sliders went in, you could not.

The fix is to drop the overlay to level 100 **only while a menu is open.** Normal
windows (0), floating windows (3), modal panels (8) and the menu bar (24) are
still covered, so the only thing that changes is our own menu. Dialogs go the
other way and raise their own level above shielding.

## What was measured when `!motion` landed

```
crt.frag defaults                     redraw = true
crt.frag all motion knobs at 0        redraw = false
crt.frag GRAIN brought back           redraw = true
water/still.frag defaults             redraw = true
print/riso.frag (does not read time)  redraw = false
crt.frag(0) → water/still.frag        redraw = true    ← the later pass flows
crt.frag(0) → print/riso.frag         redraw = false
```

A shader with no declarations is judged from source, as before. When this was
checked, `still.frag` had no markers yet; now they are on `SPEED` and `CLICK`.
`riso.frag` was removed afterwards — this table is **what was actually measured
at the time**, so the names have not been rewritten. To check the same rows
today, `print/paper.frag` stands in: it does not read `time` either.

## The screen that woke up frozen

Close the lid with the shader running, open it again, and the screen came back
wrong: the shader was clearly alive — grain moving, the hum bar rolling — over a
picture of the desktop from before the lid closed. The cursor moved normally,
because the window server draws it above the overlay and it never went through
the shader at all. `--reload` changed nothing, since re-reading a shader has
nothing to do with capture. Quitting from the menu bar and starting again fixed
it, which is a strange thing to have to know.

What is actually happening is one line of ScreenCaptureKit behaviour:

```
SCStreamErrorDomain code -3815   Failed to find any displays or windows to capture
```

A stream does not pause when the display goes away. It **ends**, `didStopWithError`
is delivered, and nothing resumes it on wake. Measured with a bare stream and a
one-second tick, on display sleep alone — no lid, no system sleep:

```
t=  5s  complete=47  ageOfLastComplete=0.1s
        !! didStopWithError -3815
t=  6s  complete=54  ageOfLastComplete=0.4s     ← the last frames in flight
t= 28s  complete=54  ageOfLastComplete=22.4s    ← awake again for seven seconds
```

The freeze that reaches the eye is the app's own doing on top of that. The redraw
timer holds the last frame so that a knob dragged on a still screen still draws
something ([the slider that did nothing](../knobs.md#the-slider-that-did-nothing-on-a-still-screen)),
and it went on pushing that frame — the one from before the lid closed — through
the shader at the refresh rate, forever. Taking the window down on the error did
not help either: the very next redraw tick counted as a frame arriving, and put
the window back up.

So three things, in the order they matter:

1. **Stop painting when the stream stops.** The redraw timer is cancelled and the
   held frame dropped. Whatever else goes wrong, a dead stream cannot be dressed
   up as a live one.
2. **Reopen the stream.** Every half second for the first four seconds, then
   backing off to five, for as long as anyone wants the capture running. While
   the screen is dark every attempt fails with the same -3815, which is exactly
   right — the one that lands after it comes back is the one that matters.
3. **Say it in the numbers.** `--status` grew `stale` (seconds since a frame came
   **from the stream** — redraw and nudge do not touch it) and `restarts`. The old
   `fps` could not have shown this: with redraw on, a capture that died at the lid
   closing goes on reporting a healthy 60.

The wake notifications (`didWake`, `screensDidWake`) are wired up too, but only as
a shortcut — they cancel the backoff so a wake does not spend up to five seconds
showing an unshaded screen. They are deliberately not the mechanism: the same
probe run as a bare process never received them at all, and recovery that depends
on a notification arriving is recovery that has a way of not happening. In
practice the notification arrives **before the display is back** — around seven
seconds before, on this machine — so the retry loop is what actually lands it.

