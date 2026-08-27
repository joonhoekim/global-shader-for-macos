#version 300 es
//
// river.frag — a flowing river. The whole screen flows one way.
//
// What the three share — why refraction, how edges (clampToEdge) and text are handled, what
// cannot be fixed about the cursor and the battery — is in the header of ./still.frag. Only
// the differences are noted here.
//
// ── What differs from still water ────────────────────────────────────────
// All three use the same substance: displace uv by the gradient of a height field. What
// makes a river a river is three things about how that height is built.
//
// **One. It has a direction.** In ./still.frag four sines face each other and shimmer in
// place; a river pushes the whole pattern one way. Sines cannot do that — sliding a sine
// makes the pattern visibly slide as a whole, which is scrolling wallpaper, not water. So
// from here on it is FBM. Noise keeps generating new pattern as it slides, so the sliding
// does not show.
//
// **Two. It is stretched.** The texture of flowing water is drawn out along the flow.
// STRETCH squeezes the noise coordinates along the flow axis alone to make that anisotropy.
// Without it there is direction but the texture stays round, which reads as "flowing fog".
//
// **Three. It bends.** Rivers do not run straight. WARP displaces the coordinates along a
// low-frequency texture (domain warping) to make eddies and meanders. That is what costs a
// second FBM evaluation, and without it the texture is parallel stripes — comb marks, not a
// river.
//
// ── The gradient, analytically ───────────────────────────────────────────
// Taking an FBM's gradient by finite differences means evaluating the FBM three times.
// noised() below returns value and gradient **together**, so once is enough. It uses the
// derivative of the cubic interpolant directly, so unlike a difference it is neither an
// approximation nor stepped.
//
// So the per-pixel cost of this file is two FBMs = eight noise evaluations = 32 hashes. All
// ALU, so it should come out cheaper than the twenty-odd texture fetches per pixel in
// ../crt/crt.frag — but the cost table in ../../docs/performance.md needs a measured number.

precision highp float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;
uniform float time;

// ── Flow ─────────────────────────────────────────────────────────────────
// The flow direction, in radians. 0 is right and 1.571 (π/2) is **down** — note that
// v_texcoord has a top-left origin, so y is positive downward. π/2 for a waterfall, near 0
// for a river.
#define ANGLE       0.35              // @0..6.283:0.01

// Flow speed. At 0 the pattern freezes, and since this is the only thing riding on time,
// redraw switches off with it (`!motion` — ../../docs/knobs.md).
#define FLOW        0.30              // @0..2:0.01 !motion

// How fine the texture is.
#define SCALE       5.0               // @1..20

// How far it stretches along the flow. 1 is isotropic and the direction does not show; 8
// draws it out like noodles. It reads as a river somewhere around 3–5.
#define STRETCH     3.5               // @1..8

// Meander. How far the coordinates are displaced along a low-frequency texture. 0 gives
// parallel stripes; past 1 the flow direction is smeared beyond recognition.
#define WARP        0.35              // @0..1

// Octaves. It has to be a constant, so it carries no mark.
#define OCTAVES     4

// ── Refraction ───────────────────────────────────────────────────────────
// A little larger than ./still.frag. A river does not set out to imitate stillness, so the
// waver belongs there — but for something left on all day, the still one is the better pick.
#define REFRACT     2.6               // @0..8
#define EDGE_FADE   0.02

// ── Protecting text ──────────────────────────────────────────────────────
// What it means and why is at the same place in ./still.frag. Refraction is larger here, so
// the default goes up a little with it.
#define PRESERVE    0.78              // @0..1
#define PRESERVE_PX 6.0               // @2..16
#define BUSY_TAPS   8
#define BUSY_LO     0.06
#define BUSY_HI     0.30

// ── Surface ──────────────────────────────────────────────────────────────
// Surface streaks. White lines laid only on the crests of the texture lying along the flow.
// Light breaking on a river reads as lines rather than points because the texture is
// stretched, so nothing has to be built for it — the stretched height serves directly.
#define STREAK      0.22              // @0..1

// Where a streak starts and over what width. It has to be narrow to catch the crests alone;
// widen it and the whole surface brightens into haze.
#define STREAK_CUT  0.55
#define STREAK_KNEE 0.30

// ── Colour ───────────────────────────────────────────────────────────────
// River water is murkier than the sea and takes on green. To change the colour, edit the
// TINT line and save (a vec3 cannot be a knob — Sources/Knobs.swift).
#define TINT_MIX    0.16              // @0..0.6
#define TINT        vec3(0.45, 0.78, 0.68)

#define BRIGHTNESS  1.02              // @0.6..1.4


vec2 aspect() {
    return vec2(screen_size.x / screen_size.y, 1.0);
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise and its gradient in one go. (value, ∂/∂x, ∂/∂y).
//
// It uses the derivative of the cubic interpolant u = f²(3-2f), du = 6f(1-f), directly.
// Unlike a finite difference it is not an approximation, so no extra samples are needed and
// there is none of the stepping a difference interval leaves — refraction uses the gradient
// directly, so that stepping would be visible on screen.
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

// Stack the octaves. The gradient has to be multiplied by the frequency too for the chain
// rule to hold — without that, the fine texture's gradient is buried under the coarse one
// and you get water with texture that does not displace.
//
// The lacunarity is 2.03 rather than 2.0 because at exactly 2 the octaves' grids line up in
// the same places and the lattice shows through.
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

// The river's height, measured in flow coordinates, with its gradient brought back to uv
// coordinates.
//
// The coordinate change is written as two dot products rather than a matrix because mat2's
// column-major convention makes it easy to get a sign wrong. Here it is visible that q.x is
// the along-flow component and q.y its orthogonal one. Bringing the gradient back is a
// matter of retracing those same two axes — a rotation is orthogonal, so its inverse is its
// transpose.
vec3 river(vec2 uv, float t) {
    vec2 dir  = vec2(cos(ANGLE), sin(ANGLE));
    vec2 perp = vec2(-dir.y, dir.x);

    vec2 p = uv * aspect() * SCALE;
    vec2 q = vec2(dot(p, dir), dot(p, perp));
    q.x /= STRETCH;            // stretch along the flow
    q.x -= t;                  // flow

    // The meander. Displaced **along the contours** of a low-frequency texture (the gradient
    // turned 90 degrees). Displacing along the contours is what makes eddies; displacing
    // along the gradient just smears the texture.
    vec3 base = fbmd(q * 0.5);
    vec2 qw = q + WARP * vec2(base.z, -base.y);

    vec3 h = fbmd(qw);

    // Bring the gradient back to q, and then to uv. The x component has to be undone by as
    // much as it was stretched. Following the warp's gradient exactly would add one more
    // Jacobian, but what refraction needs is the direction of the texture, not an exact
    // derivative, so it stops here.
    vec2 gq = vec2(h.y / STRETCH, h.z);
    return vec3(h.x, dir * gq.x + perp * gq.y);
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

    vec3 s = river(uv, time * FLOW);
    vec2 g = s.yz;

    vec2  f = smoothstep(0.0, EDGE_FADE, uv) * smoothstep(0.0, EDGE_FADE, 1.0 - uv);
    float fade = f.x * f.y;
    if (PRESERVE > 0.001) fade *= 1.0 - busy(uv, px) * PRESERVE;

    vec2 off = -g * REFRACT * px * fade;
    vec3 col = texture(tex, uv + off).rgb;

    col = mix(col, col * TINT * 1.35, TINT_MIX);

    // Streaks on the crests alone. The texture is stretched along the flow, so clipping on
    // height is enough to give lines — no direction has to be supplied separately.
    col += STREAK * smoothstep(STREAK_CUT, STREAK_CUT + STREAK_KNEE, s.x);

    col *= BRIGHTNESS;
    fragColor = vec4(col, 1.0);
}
