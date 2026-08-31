# Architecture

*[← README](../README.md)  ·  [한국어](architecture.ko.md)*

## Why there is no other structure

Hyprland *is* the compositor, so it can splice a shader into the final compose.
On macOS the WindowServer sits in that place and it publishes no hook. That
leaves three routes, and only one of them can run the shaders in this repo.

| Route | Latency | Permission | Can it read `tex`? |
|---|---|---|---|
| Gamma LUT (`CGSetDisplayTransferByTable`) | 0 | none | **No** — a per-channel 1D curve is all it is |
| Transparent overlay + blend mode | 0 | none | **No** — it can only paint on top |
| **ScreenCaptureKit → Metal → overlay** | about a frame | Screen Recording | **Yes** |

Curvature, chromatic aberration, bloom and focus in `crt.frag` all read
**outside** their own pixel. Without the screen as a texture, all four disappear
and what remains is scanlines and a vignette. That is a different shader, not
the same one. Hence capture.

So the latency, the permission and the battery are not the price of a taste
decision. They are the price of reading `tex`.

## The flow

```
SCStream (display, our app excluded)
  → CVPixelBuffer (BGRA, sRGB)
  → CVMetalTextureCache            (IOSurface shared, no copy)
  → one fragment shader
  → CAMetalLayer                   (borderless window at CGShieldingWindowLevel)
```

## Feedback — the only fatal failure in this program

If the overlay films its own output, every frame runs the shader over its own
result again. Curvature pushes on top of curvature, bloom piles on top of bloom,
and the screen **converges on a strange picture.** It looks like a ghosting
artefact, but it is not one — it does not come back.

Two layers stop it, and both are needed.

**1. Exclude our app from the stream** (`SCContentFilter(excludingApplications:)`).
Find ourselves by pid, and — **if the bundle ID is not empty** — exclude other
processes of the same bundle too. There is an API for excluding individual
windows, but a window only appears in the list after it is on screen, and it has
to be found again whenever the layout changes. Per-app is sturdier.

Never match on the empty string. `SCRunningApplication.bundleIdentifier` can be
empty (it is, when the inner binary is run directly), and comparing against an
empty value would also exclude other people's bundle-less processes from the
capture, punching holes in the screen.

**But this alone does not stop a second instance.** The `SCRunningApplication`
that `excludingApplications` takes is a **process**. Even for the same app, a
second process is not excluded from the first one's stream. Start two and each
films the other's overlay. Measured:

```
A marker read-back  74.3%     ← two instances, no defence
B marker read-back 100.0%
```

**2. Make the window itself unfilmable** (`NSWindow.sharingType = .none`).
This is a property of the window, so it holds no matter who is filming — a
second instance, or someone else's recorder. Same test:

```
A marker read-back 0.0%       ← two instances, sharingType = .none
B marker read-back 0.0%
```

On top of that an **instance lock** (`flock`) is the first line of defence and
refuses the second run outright. An overlay is "the screen looks a bit
different", so you cannot tell by eye that you started it twice — this is not a
place to lean on people being careful. The kernel releases a flock when the
process dies, so no stale lock survives a crash.

The price: **the shader does not appear in screenshots or screen recordings.**
You get the original screen. `--capturable` turns that off, but then another
capture tool can feed our output back to us.

### Reproducing and checking

```sh
global-shader --diag --exit-after 10 shaders/crt/crt.frag
```

Draws a 64px marker in the top-left over the shader, then reads that spot back
out of the **capture** on the next frame. 0% is correct; anything high is
feedback. The marker is a pass of its own, separate from the shader, so it can
be measured with the shader you actually intend to run — feedback shows up under
heavy shaders, so a diagnostic that only works with a passthrough is useless.

To produce feedback on purpose, start two with `--allow-multiple --capturable`.

## GLSL → MSL

`glslang` for SPIR-V, `spirv-cross` for MSL, then `makeLibrary(source:)` at
runtime.

Five places are searched for those two tools, first match wins — the
`GS_GLSLANG` / `GS_SPIRV_CROSS` environment variables, `Contents/Helpers/` inside
the bundle, the absolute path `build.sh` baked into `Sources/Generated.swift`,
the Homebrew prefixes (`/opt/homebrew/bin`, `/usr/local/bin`), and `PATH`.

**There is a reason the Homebrew prefixes are spelled out by hand.** A process
started from Finder or launchd inherits a `PATH` of only
`/usr/bin:/bin:/usr/sbin:/sbin` — no `/opt/homebrew/bin` in it. This is the kind
of thing that works from a terminal and fails from the icon, and if you have not
hit it before you will blame the shader.

There is one reason not to hand-write a translator. What this repo has to run
contains `fwidth` and 16-tap loops, and a hand-written translator gets some
expression **silently** wrong. A tool whose mistakes you have to catch by
looking at the screen is useless. The standard path dies with an error when it
cannot translate something.

## The two conventions

If the file contains `mainImage(` it is Shadertoy; otherwise Hyprland.

**Hyprland** — same names, same meanings as `decoration:screen_shader`.

| | |
|---|---|
| `tex` | the screen, one frame. (0,0) is top-left |
| `screen_size` | pixel size of this display |
| `pointer_position` | cursor. 0..1, origin top-left |
| `time` | seconds since it was applied |
| `pointer_pressed_positions[32]` | recent clicks. `[0]` is the most recent |
| `pointer_pressed_times[32]` | seconds elapsed **since** that click |

The loader strips `#version`, `in vec2 v_texcoord`, `out vec4 fragColor` and the
uniform declarations above, and substitutes its own. So a file written for
Hyprland drops in as-is, and that same file keeps running on Linux.

**Shadertoy** — `iChannel0` `iResolution` `iTime` `iMouse` `iFrame`. `fragCoord`
has its origin at the bottom-left as the convention requires, and
`texture(iChannel0, ...)` is flipped to match.

## Safety nets

It is a window covering the entire screen, so when something goes wrong it must
not also take away the screen you need in order to fix it.

- The window appears **after the first frame has been drawn.** With no permission
  or no capture, it covers nothing.
- A shader compile failure does not kill it. On first run it falls back to a
  passthrough; during a reload it **leaves the current one exactly as it is.** A
  single typo does not become a black screen.
- The overlay is `ignoresMouseEvents`, so every click goes through. The menu bar
  status item shows through the shader and is still clickable — you can get out
  through it even when the shader has made the screen unreadable.
- If capture stops, that display's window is taken down **and a new stream is
  opened.** Closing the lid, or letting the screen go dark on its own, does not
  pause the stream — SCK ends it (`SCStreamErrorDomain -3815`, "Failed to find any
  displays or windows to capture") and nothing brings it back on wake. Taking the
  window down is half of it; the other half is that the frame the dead stream left
  behind stops being drawn, or the screen freezes on the picture from before the
  lid closed while the shader goes on animating over it, which reads as the app
  working. See [the sleep story](notes/history.md#the-screen-that-woke-up-frozen).
- A second instance is refused, because it is feedback in itself (above).
- File saves are caught by polling every 0.4 s. Not kqueue, because vim and
  VS Code write a new file and rename on save — a watch holding an fd would be
  looking at a dead inode after the first save.
