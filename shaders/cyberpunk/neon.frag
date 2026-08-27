#version 300 es
//
// neon.frag — neon signage. It selects on **saturation**, not brightness.
//
// The tap pattern is the same as bloom() in ../crt/crt.frag; what differs is the criterion.
// There it selects on luminance, and that is right — what blooms on a CRT is where the
// phosphor burned bright. Neon is different. A white window and white text are not signage
// however bright they get; what burns is the **deep colour** over a dark background — a
// prompt colour, a syntax highlight, the primaries in an icon.
//
// So here it selects on saturation. That one line is the whole file. A grey UI panel does
// not qualify however bright it is, and one dark magenta point does however dim. Pushing a
// luminance-selected bloom hard and asking "why is the whole screen lifting" is BLOOM_CUT
// 0.22 in `crt.frag` (see that file's header); here it is not that axis to begin with.
//
// ── This file is meant to be layered ─────────────────────────────────────
// It works alone, but its place is later in a chain (../../docs/usage.md).
//
//   global-shader shaders/crt/crt.frag shaders/cyberpunk/neon.frag        a CRT in neon
//   global-shader shaders/cyberpunk/neon.frag shaders/cyberpunk/glitch.frag  the signs jump
//
// **Which is why it has no flicker.** Signage ought to flicker, but reading `time` even once
// switches redraw on and drives the GPU at the refresh rate on a still screen
// (../../docs/knobs.md). A file meant to be layered cannot decide that on its own — placed
// after `crt.frag`, this one file would throw away the "free on a still screen" that file
// works to keep. If flicker is wanted, ./glitch.frag goes after it, and the decision to pay
// the price is already in the act of choosing that file.

precision highp float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;

// ── What burns ───────────────────────────────────────────────────────────
// From this saturation, over this width, it starts to burn. At 0.18 a terminal's accent
// colours and icons qualify while grey panels, white text, and the pale colours of a photo
// wallpaper do not.
//
// At 0.08 a photo wallpaper qualifies wholesale and the whole screen glows hazily, which is
// fog, not neon.
#define CHROMA_CUT  0.18              // @0..0.6
#define CHROMA_KNEE 0.14              // @0.01..0.4

// Colours too dark are excluded. A sign that is off should not glow — without this, the deep
// navy background of a dark theme becomes a candidate in its entirety.
#define LUMA_FLOOR  0.10              // @0..0.5

// ── How it burns ─────────────────────────────────────────────────────────
// Halo strength and radius (pixels). The radius is far larger than BLOOM_PX (5) in
// `crt.frag` because the glow around a neon tube is wider than the bloom off a glyph stroke.
#define GLOW        0.85              // @0..2
#define GLOW_PX     14.0              // @2..40

// Spiral tap count. It has to be a constant, so it carries no mark (../../docs/knobs.md).
// The radius is wide, so it has to be denser than `crt.frag`'s 16 or the samples spread apart.
#define GLOW_TAPS   20

// Raises the saturation of the spreading light once more. The light around a real neon tube
// is paler than the tube itself, but on screen that just reads as a blurry smudge. The
// colour has to stand up to read as "light leaking" — legibility chosen over accuracy.
#define GLOW_SAT    1.45              // @1..2.5

// From this brightness up, the halo is not added onto the pixel itself. The same reason and
// meaning as BLOOM_KEEP in `crt.frag` — it is addition, so adding again to a surface already
// near 1.0 clips and smears the whole surface. The core of the tube has to keep its own
// brightness, with the halo left on the darker pixels around it, for a tube to read as a tube.
#define GLOW_KEEP   0.55              // @0..1

// ── Background ───────────────────────────────────────────────────────────
// Neon lives in the dark. Only low-saturation pixels are pressed down, to make the contrast —
// pressing everything down darkens the signage too and amounts to doing nothing.
#define DARKEN      0.22              // @0..0.6

// The night colour laid over the darkened background. A vec3 cannot be a knob
// (Sources/Knobs.swift) — edit and save and it applies immediately.
#define NIGHT       vec3(0.62, 0.70, 1.00)

#define BRIGHTNESS  1.04              // @0.6..1.6


// Chroma range. Not HSV's S (= (mx-mn)/mx) but mx-mn.
//
// Measured as S it blows up on dark colours — something like (0.02, 0.0, 0.0), nearly black,
// has S of 1, so every speck of a dark theme's background becomes signage. Measured as a
// range, "how deep is this colour" comes out directly, and on the dark end this value itself
// filters before LUMA_FLOOR has to.
float chroma(vec3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// The probability that this pixel is signage. 0 does not burn, 1 does.
float sign_(vec3 c) {
    return smoothstep(CHROMA_CUT, CHROMA_CUT + CHROMA_KNEE, chroma(c))
         * smoothstep(LUMA_FLOOR, LUMA_FLOOR + 0.12, luma(c));
}

// Golden-angle spiral taps. Going around in rings leaves a star-shaped grain, one point per
// direction, and a spiral does not (the same reason as bloom() in ../crt/crt.frag). Taking
// the radius as sqrt spreads samples evenly over the area.
vec3 halo(vec2 uv, vec2 px) {
    vec3  sum  = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < GLOW_TAPS; i++) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(GLOW_TAPS));
        float a  = fi * 2.39996323;          // golden angle
        float w  = exp(-r * r * 1.6);        // Gaussian weight
        vec3  c  = texture(tex, uv + vec2(cos(a), sin(a)) * r * GLOW_PX * px).rgb;
        sum  += c * sign_(c) * w;
        wsum += w;
    }
    return sum / wsum;
}

// Stands the saturation up. The mix that pulls toward grey, pushed past 1, spreads it the
// other way instead — no HSV round trip needed.
vec3 saturate_(vec3 c, float k) {
    return max(mix(vec3(luma(c)), c, k), 0.0);
}

void main() {
    vec2 px = 1.0 / screen_size;
    vec2 uv = v_texcoord;

    vec3  src = texture(tex, uv).rgb;
    float s   = sign_(src);

    // Only the background is pressed down. Where it is signage (s=1) it is left alone.
    vec3 col = src * mix(1.0 - DARKEN, 1.0, s);
    col = mix(col, col * NIGHT, DARKEN * (1.0 - s) * 0.7);

    // The halo. Not added where it is already bright (GLOW_KEEP).
    vec3 h = saturate_(halo(uv, px), GLOW_SAT);
    col += h * GLOW * (1.0 - smoothstep(GLOW_KEEP, 1.0, luma(col)));

    col *= BRIGHTNESS;

    // The overlay layer is opaque, so alpha is discarded (Sources/Renderer.swift).
    // As a middle slot in a chain the next slot reads rgb only, so it stays 1.
    fragColor = vec4(col, 1.0);
}
