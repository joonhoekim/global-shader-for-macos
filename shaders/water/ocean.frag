#version 300 es
//
// ocean.frag — a rolling sea. The whole screen rides the swell.
//
// What the three share — why refraction, how edges (clampToEdge) and text are handled, what
// cannot be fixed about the cursor and the battery — is in the header of ./still.frag. Here
// are the differences, and the price this file alone pays.
//
// ── Not meant to run all day ─────────────────────────────────────────────
// Alone among the three. REFRACT defaults to 7 pixels, and at that width the cursor drift
// described in ./still.frag's header is unmistakable — where the cursor points and where it
// actually clicks separate, and that separation moves with every passing swell. Text needs
// PRESERVE pushed to the top just to stay readable.
//
// That is written down not as a defect but as **this file's character**. Still water is
// something you leave on and work under; the sea is something you watch. So REFRACT is
// large here, and the still one was left alone.
//
// Why the three are not one file with different knobs: what makes each one what it is is
// how the height field is built, not a value. ./still.frag is four sines, ./river.frag is
// directed FBM, and this is three swell sines plus an FBM chop. Merged, they would branch,
// not vary by knob.
//
// ── The swell is sines, the chop is FBM ──────────────────────────────────
// The two are mixed. A large swell really is a few long waves overlapping, so three sines
// do it, and being sines the gradient comes out analytically. Stacking the chop out of
// sines too would make the repetition visible, so that part alone is FBM.
//
// Keeping the swell as sines brings one thing along for free. Refraction displaces along
// the gradient, and a sine wave's gradient is largest at the crest and 0 in the trough — so
// the displacement **sharpens the crests by itself**. That is the same shape a real wave
// has, sharp at the crest and round in the trough, and horizontal displacement is exactly
// what a Gerstner wave does. Nothing has to be built for it; raise REFRACT and it appears.
//
// ── Depth ────────────────────────────────────────────────────────────────
// The top of the screen is the surface and the bottom is deep. Further down, the water
// colour deepens and the red goes first — long wavelengths really are absorbed first in
// water, and it earns as much as the waves do toward reading as sea.
//
// This is perspective forced onto screen coordinates, so it is not "correct". But the lower
// part of a screen is mostly the Dock and the bottoms of windows, so darkening it loses
// little information, while the menu bar at the top stays bright — which makes it better
// than the other way around.

precision highp float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;
uniform float time;

// ── Swell ────────────────────────────────────────────────────────────────
// How fine the large waves are. Lower means longer wavelengths. Below 3 only one or two
// waves fit on screen and it reads as the whole screen tilting rather than as waves.
#define SWELL       3.4               // @1..12

// Strength of the large waves.
#define SWELL_AMP   1.00              // @0..2

// Flow speed. At 0 the swell freezes, and since this is the only thing riding on time,
// redraw switches off with it (`!motion` — ../../docs/knobs.md).
//
// The chop runs at 2.2 times this value below — short waves being faster is the same
// direction as the dispersion relation of real water, and running them at the same speed
// sticks the two layers together into one mass and the layering stops showing.
#define SPEED       0.35              // @0..1.5:0.01 !motion

// ── Chop ─────────────────────────────────────────────────────────────────
// Strength and fineness of the FBM laid over the swell. 0 leaves a smooth, oily swell alone.
#define CHOP        0.55              // @0..1
#define CHOP_SCALE  9.0               // @2..30

// Octaves. It has to be a constant, so it carries no mark. The swell already handles the
// coarse texture, so three is enough here — a fourth octave would be finer than the
// refraction width, invisible and paid for anyway.
#define OCTAVES     3

// ── Refraction ───────────────────────────────────────────────────────────
// How far what lies beyond is displaced, in pixels. As the header says, this value is what
// makes this file unsuited to running all day. To work under it, take it below 3 or use
// ./still.frag.
#define REFRACT     7.0               // @0..16
#define EDGE_FADE   0.03              // a wider fold, to match the larger REFRACT

// ── Protecting text ──────────────────────────────────────────────────────
// What it means and why is at the same place in ./still.frag. Refraction is large, so the
// default sits near the top — and even so, text does not fully stand still in this file.
// The wavelength is longer than the interval the fold works over (PRESERVE_PX), so a whole
// field of text drifting slowly together is not something it can stop.
#define PRESERVE    0.88              // @0..1
#define PRESERVE_PX 8.0               // @2..16
#define BUSY_TAPS   8
#define BUSY_LO     0.06
#define BUSY_HI     0.30

// ── Crests ───────────────────────────────────────────────────────────────
// White foam rising on the crests. The threshold has to be high and the knee narrow to catch
// the crests alone — widen it and the whole surface lifts into haze, the same failure as
// BLOOM_CUT at 0.22 in ../crt/crt.frag (the whole screen brightens instead of what should).
//
// Multiplied once by the chop so the foam is left as broken marks rather than a smooth band.
#define FOAM        0.35              // @0..1
#define FOAM_CUT    0.62
#define FOAM_KNEE   0.22

// Sun glitter. Only where the gradient tilts toward the light. The sea has larger gradients
// than still water, so the same TIGHT catches far more of it — hence tighter here.
#define SHINE       0.30              // @0..1
#define SHINE_TIGHT 40.0              // @2..120

// The light direction. y is positive downward (v_texcoord has a top-left origin), so this is the upper left.
#define LIGHT       normalize(vec3(-0.30, -0.42, 1.0))

// ── Colour ───────────────────────────────────────────────────────────────
// How much water tint is mixed in (at the surface). DEPTH below adds to this further down.
#define TINT_MIX    0.16              // @0..0.6

// Not a knob — a vec3 does not fit in one uniform (Sources/Knobs.swift).
// Edit and save and it applies immediately.
#define TINT        vec3(0.28, 0.60, 0.92)

// How much it deepens toward the bottom. 0 makes the whole screen the same depth.
#define DEPTH       0.35              // @0..1

// How far the red channel drops away in the deep. Long wavelengths being absorbed first in
// water, kept separate from DEPTH — sometimes you want it deeper without shifting the colour.
#define ABSORB      0.30              // @0..1

#define BRIGHTNESS  1.04              // @0.6..1.4


vec2 aspect() {
    return vec2(screen_size.x / screen_size.y, 1.0);
}

// One layer. (height, gradient x, gradient y). The same function as in ./still.frag.
vec3 wave(vec2 p, vec2 k, float speed, float amp, float t) {
    float ph = dot(p, k) + t * speed;
    return vec3(amp * sin(ph), amp * k * cos(ph));
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise and its gradient in one go. Why not finite differences is on the same
// function in ./river.frag.
vec3 noised(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u  = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    float k1 = b - a, k2 = c - a, k3 = a - b - c + d;
    return vec3(a + k1 * u.x + k2 * u.y + k3 * u.x * u.y,
                du.x * (k1 + k3 * u.y),
                du.y * (k2 + k3 * u.x));
}

// Why the lacunarity is 2.03 (overlapping grids) and why the gradient is multiplied by the
// frequency (the chain rule) is on the same function in ./river.frag.
vec3 fbmd(vec2 p) {
    vec3  s = vec3(0.0);
    float amp = 0.5, freq = 1.0;
    for (int i = 0; i < OCTAVES; i++) {
        vec3 n = noised(p * freq);
        s.x  += amp * n.x;
        s.yz += amp * freq * n.yz;
        amp  *= 0.5;
        freq *= 2.03;
    }
    return s;
}

// Three swell layers. The wave numbers are not integer multiples of each other, and all
// three go broadly the same way — scattered directions read as boiling water, not swell.
vec3 swell(vec2 p, float t) {
    return wave(p, vec2( 1.00,  0.26), 1.00, 1.00, t)
         + wave(p, vec2( 0.71,  0.63), 0.79, 0.62, t)
         + wave(p, vec2( 1.23, -0.41), 1.27, 0.35, t);
}

// How crowded with small text this spot is. Why the mean rather than the maximum, and why
// the taps are a spiral, is on the same function in ./still.frag.
float busy(vec2 uv, vec2 px) {
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    float c = dot(texture(tex, uv).rgb, W);
    float e = 0.0;
    for (int i = 0; i < BUSY_TAPS; i++) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(BUSY_TAPS));
        float a  = fi * 2.39996323;
        vec2  o  = vec2(cos(a), sin(a)) * r * PRESERVE_PX * px;
        e += abs(dot(texture(tex, uv + o).rgb, W) - c);
    }
    return smoothstep(BUSY_LO, BUSY_HI, e / float(BUSY_TAPS));
}

void main() {
    vec2 px = 1.0 / screen_size;
    vec2 uv = v_texcoord;
    vec2 a  = aspect();

    vec3 s = swell(uv * a * SWELL, time * SPEED) * SWELL_AMP;
    vec3 c = fbmd(uv * a * CHOP_SCALE + vec2(time * SPEED * 2.2, 0.0));

    // The chop's gradient carries the fineness as a factor (the chain rule). Added as is,
    // raising CHOP would bury the swell under the fine texture, so it is divided by the
    // fineness once to keep CHOP meaning "strength".
    float h = s.x + CHOP * c.x;
    vec2  g = s.yz + CHOP * c.yz / CHOP_SCALE;

    vec2  f = smoothstep(0.0, EDGE_FADE, uv) * smoothstep(0.0, EDGE_FADE, 1.0 - uv);
    float fade = f.x * f.y;
    if (PRESERVE > 0.001) fade *= 1.0 - busy(uv, px) * PRESERVE;

    // The crests sharpening by themselves is this one line (see the header).
    vec2 off = -g * REFRACT * px * fade;
    vec3 col = texture(tex, uv + off).rgb;

    // Depth. Deeper toward the bottom, with the red dropping away.
    float depth = uv.y;
    col = mix(col, col * TINT * 1.35, TINT_MIX + DEPTH * depth * 0.6);
    col.r *= 1.0 - ABSORB * depth;

    // Foam on the crests. Multiplied once by the chop, so it is broken marks rather than a smooth band.
    float crest = smoothstep(FOAM_CUT, FOAM_CUT + FOAM_KNEE, h);
    col += FOAM * crest * smoothstep(0.35, 0.75, c.x);

    // Sun glitter.
    vec3 n = normalize(vec3(-g, 1.0));
    col += SHINE * pow(max(dot(n, LIGHT), 0.0), SHINE_TIGHT);

    col *= BRIGHTNESS;

    // The overlay layer is opaque, so alpha is discarded (Sources/Renderer.swift).
    fragColor = vec4(col, 1.0);
}
