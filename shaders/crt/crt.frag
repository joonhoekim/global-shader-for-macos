#version 300 es
//
// crt.frag — a CRT over the whole screen. Hyprland's decoration:screen_shader.
//
// One finished frame of the screen comes in and is drawn once more at the end. Not one
// window: wallpaper, bars, windows, and cursor all go behind the same glass.
//
// ── Motion is switched off with knobs ────────────────────────────────────
// The moving parts — grain, hum bar, click ripples — all sit behind knobs. Set these four
// groups to 0 and nothing moves:
//
//   GRAIN 0    HUM 0 · HUM_LIFT 0 · HUM_GLOW 0    RIPPLE_GAIN/LIFT/GLOW 0
//
// That has to be free, or a still CRT would want its own file. Two things make it free.
//
// **One. Uniform branches.** A value promoted to a knob is a uniform, so the compiler
// cannot fold it — GRAIN at 0 still runs the grain code for every pixel. Wrapped in
// `if (GRAIN > 0.0)` in main(), the branch turns on a single uniform, so the whole warp
// goes the same way and it really does not run. Unwrapped, the difference between a still
// and a moving CRT (12.1ms → 14.0ms) becomes a permanent cost.
//
// **Two. The `!motion` mark.** The automatic redraw decision looks for `time` in the
// source. On that alone, this file would always count as moving even at GRAIN=0, and the
// one thing it has going for it — costing nothing on a still screen — would be gone. So a
// knob carries `!motion` next to its range, the shader declaring "this one opens and
// closes time" — with every marked knob at 0, redraw switches off. The details are in
// ../../docs/knobs.md, "Knobs that open and close time".
//
// **On Linux neither of these exists.** `!motion` is just a comment and the `#define`s are
// constants, so the compiler folds the branches (which is why the cost is 0 there too).
// But Hyprland requires `debug:vfr = false` for any shader using `time`, so VFR has to be
// off regardless of the values. That is the compositor's call, not this file's.
//
// ── Damage tracking ──────────────────────────────────────────────────────
// `debug:damage_tracking = 0` is always needed, motion or not. curve(), gun(), and bloom()
// read outside their own pixel, so recompositing only the changed rectangle leaves the
// neighbours around it stale. macOS does not have this problem — here a whole frame of the
// screen arrives every frame.
//
// ── Origin ───────────────────────────────────────────────────────────────
// Adapted from a shader applied to a single ghostty terminal window. Values tuned for one
// window are too strong across a whole screen — the comments below say where each one came
// down and why.
//
// That terminal shader in turn descends from **Maxim Samoliuk's Hyprland screen shader
// (MIT)**, which shipped in the space_dots (Golden Era) rice. Bloom, grain, flicker,
// chromatic aberration, and the edge treatment were all rewritten, but it is a derivative
// work and is credited here. See ../../LICENSE.
//
// Edits take effect the moment you save.

precision highp float; // mediump will not do — at pixel coordinates like 2560 the
                       // precision grows coarser than a pixel and scanlines smear.

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size; // pixel size of this monitor. fullSize / screenSize are the same.
uniform float time;       // seconds since the shader was applied.

// ── Pointer ──────────────────────────────────────────────────────────────
// These uniforms are undocumented. renderToOutputInternal() in 0.56 passes them to screen
// shaders (src/render/OpenGL.cpp). They all require debug:damage_tracking = 0, which this
// file has to turn off anyway, so **they cost nothing extra**.
//
// Coordinates are normalized 0..1, local to this monitor, and in the texture space
// **before curvature**. So comparing directly against a uv that has been through curve()
// is right — the cursor bends with the screen because it is already drawn into the texture.
uniform vec2  pointer_position;

// Click history. Index 0 is the most recent, and each new click pushes the rest forward
// (addLastPressToHistory in OpenGL.cpp). times are the **real seconds** elapsed since each
// click, so they are unaffected by ANIM_SPEED below.
//
// Both are 32 long (POINTER_PRESSED_HISTORY_LENGTH in macros.hpp). There is a Hyprland bug
// on the positions side which, as it happens, does not affect this declaration:
//
//   shader->setUniform2fv(SHADER_POINTER_PRESSED_POSITIONS, pressedPos.size(), ...)
//   //                                       ↑ the float count (64), not the vec2 count (32)
//
// glUniform2fv's count is a vec2 count, so passing 64 makes it try to read 128 floats —
// the buffer holds 64, so Hyprland reads past its own buffer (on 0.56.1 and on main alike).
// But **elements beyond the end are ignored rather than an error** (OpenGL ES 3.0: "values
// for all array elements beyond the end of the array will be ignored"), so declaring [32]
// receives the first 32 intact and the rest are dropped. Verified at [32] with
// debug:gl_debugging = true — no GL errors.
uniform vec2  pointer_pressed_positions[32];
uniform float pointer_pressed_times[32];

#define TAU 6.2831853

// ── Shape ────────────────────────────────────────────────────────────────
// Barrel distortion. It was 0.18 in the terminal. Across a whole screen, window borders and
// bars bend along with it, so the same value reads far stronger. Hence lower.
//
// 0.20 makes the glass more convincing at two costs. One is clipping — curve() only pushes
// the screen outward without shrinking it, so about 4% of each corner goes under the bezel
// (the push rides on uv.x²·uv.y², so the *middle* of each edge is untouched). Overscan
// could deal with that.
//
// The one that cannot be dealt with is the real reason: **the cursor drifts from where it
// actually clicks.** The cursor is drawn into the texture and then bends with the screen,
// while the pointer coordinates do not, and correcting it belongs in the compositor rather
// than the shader. Raising curvature means that correction first.
#define CURVE       0.10              // @0..0.3

// How wide the screen edge dies off, in pixels. Just enough not to stairstep the curve.
#define EDGE_SOFT   1.5

// Vignette exponent. It is pow(brightness, VIGNETTE), so *larger* darkens the edges more
// deeply and 0 removes it entirely — an exponent near 0 flattens pow toward 1.
// The terminal's 0.25 was far too strong across a whole screen. There the edge is just
// margin outside a window border; here the bar and tray live there permanently, and things
// that must not darken do. This is a fifth of that.
#define VIGNETTE    0.06              // @0..0.5

// ── Optics ───────────────────────────────────────────────────────────────
// Focus. 0 leaves the original alone; 1 smears about a pixel. It was 0.5 in the terminal,
// but here small UI text is everywhere and the readability cost is much higher.
//
// This value also lands directly on brightness. A white glyph stroke is a pixel or two, so
// most of its neighbours are black, and blurring drops the stroke's peak from 1.0 to about
// 0.85 — and scanlines, grille, and gamma all then work on that lowered value. This is
// where "white text on black looks faint" starts.
#define FOCUS       0.18              // @0..0.6

// How much blur to keep around the cursor, and over what range (relative to screen
// *height*). At 0.25 that spot alone sharpens to a quarter of FOCUS.
//
// Sharpening the whole glass stops it being a CRT; blurring all of it makes small text
// unreadable. Sharpening only where you are looking does both — no real CRT behaves this
// way, but read as an extension of an electron gun focusing best at the centre of the
// screen, it is not far off the grain. FOCUS_NEAR at 1.0 turns this off.
#define FOCUS_NEAR  0.25              // @0..1
#define FOCUS_RADIUS 0.13              // @0.02..0.4

// Chromatic aberration. How far R and B separate at the screen edge, in pixels. 0 at the centre.
#define ABERRATION  3.0               // @0..8

// Bloom. Radius in pixels, and from what brightness over what width it begins to spread.
//
// **This is the most expensive part of the shader** — 16 taps per pixel, which across a
// whole screen is tens of millions of texture fetches per frame. On integrated graphics,
// this is the first thing to cut when frames run short: BLOOM at 0.0 still runs the loop,
// so lowering TAPS to 8 or deleting the bloom() call is what actually gets cheaper.
//
// At BLOOM_CUT 0.22, grey UI panels cleared the threshold wholesale, and what lifted was
// the entire screen rather than what should bloom (bright glyphs). That is half of "too
// bright and no contrast". The threshold moved above the midtones and the strength came
// down — now only white text and accent colours bloom.
#define BLOOM       0.32              // @0..1
#define BLOOM_PX    5.0               // @1..16
#define BLOOM_CUT   0.45              // @0..1
#define BLOOM_KNEE  0.25              // @0.01..0.6
#define BLOOM_TAPS  16

// From this brightness up, bloom is not added onto the pixel itself. 1.0 adds it everywhere.
//
// This is the other half. Bloom is addition, so on a broad bright surface like a white
// window it lands on values already near 1.0 and clips in the framebuffer — that is bright
// areas smearing into mush. Taking bloom off bright pixels lets the surface keep its own
// brightness while the spread stays on the darker pixels around it.
//
// It is also closer to the truth. What you see on a CRT is not the emitting surface but the
// light leaking around it. On white text over black, the stroke keeps its brightness and
// only its surroundings get a halo, which actually makes the text stand out more.
#define BLOOM_KEEP  0.35              // @0..1

// ── Stripes ──────────────────────────────────────────────────────────────
// Scanline period (pixels) and depth. Keeping the period in pixels holds the same thickness on HiDPI.
#define SCAN_PX     4.0               // @2..8
#define SCAN_DEPTH  0.12              // @0..0.5

// Phosphor grille. R/G/B subpixel stripes. Overlapping the scanlines makes it look like
// insect screen, so it stays shallow enough only to be felt.
#define GRILLE      0.06              // @0..0.3
#define GRILLE_PX   3.0

// ── Colour ───────────────────────────────────────────────────────────────
// Contrast. A pow exponent, so 1.0 leaves it alone and larger deepens the dark end. Same
// direction as a CRT's gamma being steeper than sRGB's (2.4 against 2.2).
//
// **Use it thinly.** 1.35 gives "the bright parts are brighter and the dark parts far too
// dark". The exponent does leave 1.0 alone, true — but white text arriving here is no
// longer at 1.0: focus blur took it to 0.85 and scanlines and grille cut it again by 0.83,
// so it takes gamma square on. Where blacks need pressing down, BLOOM_KEEP above does it
// far more precisely, at the cause. This is the finish.
#define CONTRAST    1.08              // @0.6..2

// Puts back what the scanlines and grille cut away. In a trough where both overlap it goes
// down to 0.83, so the correction is real — at 1.0 white text goes faint.
#define BRIGHTNESS  1.12              // @0.6..1.8

// Phosphor tint. vec3(1.0) leaves the palette alone. This one line gives another look —
// amber vec3(1.15, 0.85, 0.45), green vec3(0.65, 1.20, 0.70).
#define TINT        vec3(1.0)


// ── Motion ───────────────────────────────────────────────────────────────
// Everything from here on moves. What carries `!motion` is a knob that opens and closes
// time, and with all of them at 0 redraw switches off and a still screen costs nothing
// (see the header).
//
// ANIM_SPEED does not carry `!motion`. At 0 the grain pattern and the hum bar are still
// there in place (stopped, not gone), and click ripples run on real seconds and keep
// moving — it is not the condition for "nothing is moving".
#define ANIM_SPEED  0.45              // @0.05..2

// Analogue grain. Strength, blob size (pixels), and how many new patterns per second.
// grainAt() subtracts the low-frequency component, so GRAIN_PX sets texture alone and has
// nothing to do with the whole screen pulsing brighter and darker. That is also why
// GRAIN_HZ is high — it avoids the 3–15Hz band the eye is most sensitive to for flicker.
#define GRAIN       0.030             // @0..0.15 !motion
#define GRAIN_PX    1.5
#define GRAIN_HZ    40.0              // @5..60

// How the speckle is distributed. Addition alone is lost in bright areas; multiplication
// alone vanishes in black (black × anything is black). Mixed, it lands evenly everywhere.
#define GRAIN_ADD   1.0    // the share in dark areas
#define GRAIN_MUL   1.4    // the share in bright areas

// Hum bar — the brightness band from mains frequency beating against the vertical scan. Not
// a sine sweeping the whole screen but one narrow band rolling slowly downward. At any
// instant only HUM_WIDTH of the screen is affected, so the eye reads it as "something went
// past" rather than "the screen changed". One pass takes 1 / (HUM_SPEED × ANIM_SPEED)
// seconds.
//
// Lower than in the terminal (pure black background). A desktop is already bright with
// wallpaper and windows, so the same strength makes the band far more conspicuous.
//
// All three carry `!motion` because any one of them above 0 makes the band visible.
#define HUM_LIFT    0.015             // @0..0.1 !motion how much black lifts inside the band — without it, nothing shows
#define HUM         0.04              // @0..0.3 !motion how much brighter bright pixels get inside the band
#define HUM_GLOW    1.2               // @0..4 !motion how much more bloom spreads inside the band
#define HUM_WIDTH   0.10              // @0.02..0.4 band height (fraction of screen height)
#define HUM_SPEED   0.25              // @0..1 screens per second it descends

// Click ripple — one ring spreading from where you pressed. Applied with the same grammar
// as the hum bar, so the values mean the same things (GAIN is the bright pixels' share,
// LIFT the black's, GLOW the bloom multiplier).
//
// This is not out of place on a CRT because it shares its grammar with the electron beam
// momentarily brightening what it passes over. A real CRT has no notion of a click, but the
// screen brightening once in response to something is what this glass does all the time.
//
// The time comes from pointer_pressed_times, which is real seconds, so ANIM_SPEED does not
// apply. A response to input that follows the screen's animation speed drifts from the hand
// and feels late.
#define RIPPLE_SEC  0.55              // @0.1..2 seconds for one to fade out
#define RIPPLE_MAX  0.20              // @0.02..0.6 radius when fully spread (fraction of screen height)
#define RIPPLE_W    0.030             // @0.005..0.15 ring thickness. Thin reads as a wave, thick as a flash
#define RIPPLE_GAIN 0.35              // @0..1.5 !motion
#define RIPPLE_LIFT 0.05              // @0..0.3 !motion
#define RIPPLE_GLOW 1.5               // @0..4 !motion
// How many recent clicks to overlap. The history holds 32, but nobody clicks that often
// within RIPPLE_SEC, and the loop costs per pixel.
// How many recent clicks to overlap. The history holds 32, but nobody clicks that often
// within RIPPLE_SEC, and the loop costs per pixel.
#define RIPPLE_TAPS  6


vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 bulge = abs(uv.yx) * CURVE;
    uv += uv * bulge * bulge;
    return uv * 0.5 + 0.5;
}

// Hash without banding (Dave Hoskins family). The sin(dot(...)) kind repeats its pattern as
// coordinates grow, which reads as a grid rather than speckle.
float hash(vec2 p, float seed) {
    vec3 v = fract(vec3(p.x, p.y, p.x) * 0.1031 + seed * 0.1731);
    v += dot(v, v.yzx + 33.33);
    return fract((v.x + v.y) * v.z);
}

// Value noise. Sampled on a grid and smoothly joined, so it gives blobs the size of
// GRAIN_PX rather than per-pixel sand.
float vnoise(vec2 p, float seed) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i,                  seed), hash(i + vec2(1.0, 0.0), seed), f.x),
               mix(hash(i + vec2(0.0, 1.0), seed), hash(i + vec2(1.0, 1.0), seed), f.x), f.y);
}

// High-pass grain. Subtracting noise four times coarser from fine noise makes the average
// over a broad area converge to 0 — that low frequency was the whole screen pulsing.
float grainAt(vec2 p, float seed) {
    return vnoise(p / GRAIN_PX, seed) - vnoise(p / (GRAIN_PX * 4.0), seed + 7.0);
}

// Without multiplying by the aspect ratio this would be an ellipse stretched horizontally —
// uv runs 0..1 on both axes, so the same distance is wider horizontally by the aspect
// ratio. Measuring against height keeps the radius values the same size across monitors.
vec2 aspect() {
    return vec2(screen_size.x / screen_size.y, 1.0);
}

// The focus blur for this pixel. Closer to the cursor moves toward FOCUS_NEAR.
float focusAt(vec2 uv) {
    vec2 d = (uv - pointer_position) * aspect();
    float near = exp(-dot(d, d) / (FOCUS_RADIUS * FOCUS_RADIUS));
    return mix(FOCUS, FOCUS * FOCUS_NEAR, near);
}

// The summed strength recent clicks leave on this pixel. 0 means nothing is happening.
float ripples(vec2 uv) {
    float acc = 0.0;
    vec2  a   = aspect();

    for (int i = 0; i < RIPPLE_TAPS; i++) {
        float age = pointer_pressed_times[i];
        // A slot never clicked carries the time since the compositor started, which is very
        // large. So this one line filters it out with no separate "empty" marker.
        if (age > RIPPLE_SEC) continue;

        float k = age / RIPPLE_SEC;             // 0 → 1
        float r = length((uv - pointer_pressed_positions[i]) * a);

        // The radius grows while the thickness holds. Growing the thickness too would make
        // it a widening disc rather than a ring, and there would be a moment where half the
        // screen brightens.
        //
        // Multiplication rather than pow(x, 2.0). GLSL's pow is undefined for a negative
        // base, and this base is negative inside the ring — the hum bar uses multiplication
        // in the same place for the same reason.
        float e = (r - k * RIPPLE_MAX) / RIPPLE_W;
        acc += exp(-e * e) * (1.0 - k);
    }
    return acc;
}

// Fires the three electron guns separately (no divergence at the centre) and mixes focus
// blur into that. A diagonal 4-tap tent, so 7 taps and done.
vec3 gun(vec2 uv, vec2 px, float focus) {
    vec2 drift = (uv - 0.5) * ABERRATION * px * 2.0;
    vec3 sharp = vec3(
        texture(tex, uv + drift).r,
        texture(tex, uv).g,
        texture(tex, uv - drift).b
    );

    vec2 r = px * 0.8;
    vec3 soft = texture(tex, uv + vec2( r.x,  r.y)).rgb
              + texture(tex, uv + vec2(-r.x, -r.y)).rgb
              + texture(tex, uv + vec2( r.x, -r.y)).rgb
              + texture(tex, uv + vec2(-r.x,  r.y)).rgb;

    return mix(sharp, soft * 0.25, focus);
}

// Golden-angle spiral taps. Taking the radius as sqrt is what spreads samples evenly over
// the area. Going around in rings leaves a star-shaped grain around bright text; a spiral
// does not.
vec3 bloom(vec2 uv, vec2 px) {
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < BLOOM_TAPS; i++) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(BLOOM_TAPS));
        float a  = fi * 2.39996323;          // golden angle
        float w  = exp(-r * r * 1.8);        // Gaussian weight
        vec3  c  = texture(tex, uv + vec2(cos(a), sin(a)) * r * BLOOM_PX * px).rgb;
        float l  = dot(c, vec3(0.2126, 0.7152, 0.0722));
        sum  += c * smoothstep(BLOOM_CUT, BLOOM_CUT + BLOOM_KNEE, l) * w;
        wsum += w;
    }
    return sum / wsum;
}

// Lays one effect over the screen. gain is the share on bright pixels, lift the share on
// black. Either one alone is invisible on one side (see the GRAIN_ADD/GRAIN_MUL note above).
vec3 modulate(vec3 col, float amount, float gain, float lift) {
    return col * (1.0 + amount * gain) + vec3(amount * lift);
}

// Scanlines and phosphor grille. Measured in curved coordinates (pix), so they bend with the screen.
vec3 stripes(vec3 col, vec2 pix) {
    // How much of a stripe fits inside one screen pixel. Past half a period it cannot be
    // represented at all and only moiré is left — so the stripes fade out where that happens,
    // which is mostly at the strongly curved edges. Absent beats messy.
    float scanAA   = 1.0 - smoothstep(0.25, 0.5, fwidth(pix.y) / SCAN_PX);
    float grilleAA = 1.0 - smoothstep(0.25, 0.5, fwidth(pix.x) / GRILLE_PX);

    col *= 1.0 - SCAN_DEPTH * scanAA * (0.5 + 0.5 * sin(pix.y * TAU / SCAN_PX));

    float gp = pix.x * TAU / GRILLE_PX;
    vec3 mask = 0.5 + 0.5 * vec3(sin(gp), sin(gp + TAU / 3.0), sin(gp + TAU * 2.0 / 3.0));
    return col * (1.0 - GRILLE * grilleAA * mask);
}

// Inside the glass — vignette and the screen edge. Cutting away outside the curvature with
// an if leaves the curve stairstepped, so it dies off smoothly over EDGE_SOFT pixels.
vec3 bezel(vec3 col, vec2 uv) {
    // With uv outside the screen the product is negative and pow returns NaN. Removing the
    // hard cut is what this guards.
    vec2 e = uv * (1.0 - uv.yx);
    col *= smoothstep(0.0, 1.0, pow(max(e.x * e.y, 0.0) * 30.0, VIGNETTE));

    vec2 d = min(uv, 1.0 - uv) * screen_size;
    return col * smoothstep(0.0, EDGE_SOFT, min(d.x, d.y));
}

void main() {
    vec2 px  = 1.0 / screen_size;
    vec2 uv  = curve(v_texcoord);

    // Scanlines and grille are measured in curved coordinates, so they bend with the screen.
    vec2 pix = uv * screen_size;

    float t = time * ANIM_SPEED;

    // ── The moving parts ─────────────────────────────────────────────────
    // All three sit behind uniform branches. With the knob at 0 they **really do not run** —
    // the branch turns on a single uniform, so the whole warp goes the same way. Without
    // these branches, GRAIN at 0 would still run the grain code for every pixel and the
    // difference between a still and a moving CRT would be a permanent cost (see the header).
    //
    // With promotion off, or on Linux, these are plain constants and the compiler folds
    // them. Either way the cost is 0.

    // Hum bar position. Wrapped with fract, and the band comes from the shortest distance
    // in those wrapped coordinates.
    float humBar = 0.0;
    if (HUM + HUM_LIFT + HUM_GLOW > 0.0) {
        float humY = fract(uv.y + t * HUM_SPEED);
        float humD = min(humY, 1.0 - humY);
        humBar = exp(-(humD * humD) / (HUM_WIDTH * HUM_WIDTH));
    }

    // Recent clicks. They land in the same place as the hum bar, so they are computed here too.
    float rip = 0.0;
    if (RIPPLE_GAIN + RIPPLE_LIFT + RIPPLE_GLOW > 0.0) {
        rip = ripples(uv);
    }

    // Bloom is pushed far harder. Bright things flaring around their edges as the band goes
    // past is what actually stands out on a CRT. Ripples ride the same multiplier — bright
    // things flaring once at the point of the click registers before the ring itself does.
    //
    // **This multiplication is why this cannot be split into a chain.** Moving the hum bar
    // and ripples into a later slot would leave that slot with the composited colour alone
    // and no way to touch the bloom term, and this flare — the most visible part — would be
    // gone entirely.
    float humGlow = 1.0 + HUM_GLOW * humBar + RIPPLE_GLOW * rip;

    vec3 col = gun(uv, px, focusAt(uv));

    // Bright pixels keep their own brightness and the spread lands only on the darker pixels
    // around them. What the hum bar and ripples push sits behind this gate too — it is what
    // stops the screen clipping wholesale as the band passes over a white window.
    float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col += bloom(uv, px) * BLOOM * humGlow * (1.0 - smoothstep(BLOOM_KEEP, 1.0, lum));

    col = stripes(col, pix);

    // Grain steps at GRAIN_HZ, with the steps joined by a smoothstep. Snapping straight to a
    // new pattern is what becomes visible sizzle. The coordinates are screen pixels rather
    // than curved ones — the speckle is in the glass, not in front of it.
    if (GRAIN > 0.0) {
        float ts = t * GRAIN_HZ;
        float g  = mix(grainAt(gl_FragCoord.xy, floor(ts)),
                       grainAt(gl_FragCoord.xy, floor(ts) + 1.0),
                       smoothstep(0.0, 1.0, fract(ts)));
        col = modulate(col, g * GRAIN, GRAIN_MUL, GRAIN_ADD);
    }

    // Outside the band humBar is 0 and nothing happens.
    col = modulate(col, humBar, HUM, HUM_LIFT);
    col = modulate(col, rip, RIPPLE_GAIN, RIPPLE_LIFT);

    // Contrast has to come after every addition (bloom, grain, ripple). Its purpose is
    // pressing the lifted blacks back down, so placed earlier it would do nothing. Being
    // before the vignette (bezel) is the opposite reason — the edges dying off is already a
    // multiplication and needs no further cut here. max() is because grain can push values
    // near black negative — pow(negative, fractional) is NaN.
    col = pow(max(col, 0.0), vec3(CONTRAST));

    col  = bezel(col, uv);
    col *= BRIGHTNESS * TINT;

    // A screen shader's result goes straight to the framebuffer. Outside the curvature was
    // killed to black above, and that is the CRT bezel — so alpha is always 1.
    fragColor = vec4(col, 1.0);
}
