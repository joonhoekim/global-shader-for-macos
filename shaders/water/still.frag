#version 300 es
//
// still.frag — still water. The whole screen goes under a shallow pool.
//
// The reference file of the three water shaders (./still.frag, ./river.frag,
// ./ocean.frag). Everything the three share — why refraction, how edges and text are
// handled, what cannot be fixed — is written here, and the other two note only what
// differs. That they are duplicates, with no way to share values or functions, is the same
// situation as ../crt/crt.frag (screen shaders are not preprocessed, so there is no
// #include).
//
// ── Why refraction ───────────────────────────────────────────────────────
// Laying blue over the screen is not water. What reads as water is **what lies beyond it
// being displaced**, and that means the shader has to read outside its own pixel.
//
// So this file sits on the side of the table in ../../docs/architecture.md that only the
// capture route can serve. Neither a gamma LUT nor a blend overlay can read `tex`, so on
// those two routes the tint is all that survives and the water is gone. The same place
// curvature in ../crt/crt.frag justifies capture.
//
// Which makes the substance of this shader exactly two lines — take the gradient of a
// height field h, and read uv displaced by that gradient. Colour and glint are decoration
// on top.
//
// ── Ripples are four sines, not noise ────────────────────────────────────
// The river and the ocean use FBM; this does not. The texture of still water really is an
// interference pattern of a few long waves, and building it from noise makes it fizz,
// which stops it being "still". Four sines also means the gradient can be taken
// **analytically** — no extra samples the way finite differences would need, and none of
// the stepping a difference leaves behind.
//
// The wave vectors must not be integer multiples of each other. Integer multiples repeat
// the pattern into a lattice, and that is wallpaper rather than water.
//
// ── The price ────────────────────────────────────────────────────────────
// **Redraw switches on.** It reads `time`, so a still screen is drawn at the refresh rate
// (../../docs/knobs.md). ../crt/crt.frag does not read time and costs nothing on a still
// screen; water has no such option — if it does not move, it is not water. This is where
// the battery goes on a laptop.
//
// **The cursor drifts.** The window server draws the cursor *above* the overlay, so it
// gets no shader (../../docs/performance.md). In a refraction shader that becomes a new
// problem — the pixel the cursor points at is actually displaced by REFRACT pixels, so
// cursor and target visibly separate. Curvature in ../crt/crt.frag has the same problem,
// but that one is stationary and this one moves. There is no fixing it from the shader
// side — which is why REFRACT defaults to a small 1.6 pixels here, and the large values
// live in ./ocean.frag, which is not meant to run all day.
//
// ── Edges ────────────────────────────────────────────────────────────────
// The sampler is clampToEdge (Sources/Renderer.swift). A displaced uv leaving the screen
// stretches the border row into a streak, putting an unidentifiable band along all four
// sides. Folding the displacement to 0 over EDGE_FADE stops that. Colour and glint are not
// folded — they read nothing outside, so there is no reason to, and folding them would
// leave only the border looking unlike water.

precision highp float; // mediump will not do — the refraction width is in pixels, and once
                       // precision is coarser than a pixel the displacement steps.

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;

// Seconds since it was applied. This one line brings the redraw price above.
uniform float time;

// Click history. [0] is the most recent, and times are the seconds **since** each click.
// The array size of 32 and why is in the header of ../crt/crt.frag.
uniform vec2  pointer_pressed_positions[32];
uniform float pointer_pressed_times[32];

// ── Texture ──────────────────────────────────────────────────────────────
// How fine the ripples are — close to how many waves cross the height of the screen. Above
// 24 it starts reading as a diamond lattice rather than water, because once the wavelength
// approaches the refraction width, neighbouring crests and troughs fold onto the same pixel.
#define RIPPLE      6.0               // @1..24

// Flow speed. At 0 the pattern freezes.
//
// This and CLICK below both have to be 0 for redraw to switch off — with this at 0, click
// ripples still run on real seconds. Hence the mark on both (`!motion` — ../../docs/knobs.md).
#define SPEED       0.20              // @0..1.5:0.01 !motion

// Chop. The strength of the short waves laid over the two long ones above. At 0 only the
// large waves remain and it is glass-smooth; at 1 it gets fine, as if the wind had touched it.
#define CHOP        0.35              // @0..1

// ── Refraction ───────────────────────────────────────────────────────────
// How far what lies beyond is displaced, in pixels. **The most important value here.**
//
// It is 1.6 because of the cursor drift in the header. Past 3 the water is more convincing,
// but where the cursor points and where it actually is separate visibly, and text wavers
// while you read. The ceiling for something you can leave on and work under is around here.
#define REFRACT     1.6               // @0..8

// The edge width over which displacement folds to 0 (0..1). 2% is about 60 pixels at a
// width of 2940, so even REFRACT 8 reads nothing outside. It is not exposed as a knob
// because it is not taste — it is the fixed value that keeps clampToEdge out.
#define EDGE_FADE   0.02

// ── Protecting text ──────────────────────────────────────────────────────
// How far displacement folds where small text is dense. At 0 the whole screen wavers equally.
//
// underwater.frag in xatuke/screenshader, which this took a cue from, protects text by
// **mixing the original colour back** into the refracted one. That strips the water tint
// around the text alone and leaves a rectangular patch. Here it is not the colour but
// **the displacement itself** that is reduced — the text stands still while the water tint
// stays even across the whole screen. It also costs one fetch less, with no need to read
// the original separately.
//
// The crux is that the fold has to be gradual. Removing displacement on glyph strokes alone
// makes stroke and counter move differently within one letter, and the letter **tears** —
// worse than wavering. So busy() below returns a value blurred over a PRESERVE_PX radius.
#define PRESERVE    0.70              // @0..1

// The radius for finding text, in pixels. It has to cover a whole glyph, or the tearing
// above appears. Body strokes are 2–3 pixels on a HiDPI backing store, so 6 is ample.
#define PRESERVE_PX 6.0               // @2..16

// Spiral tap count. It has to be a constant, so it carries no mark (../../docs/knobs.md).
#define BUSY_TAPS   8

// From what to what counts as "there is text here". Paired with busy() below measuring
// **the mean rather than the maximum** — one window border cannot fill this interval, and
// only a place dense with strokes does. Measured by maximum, one high-contrast wallpaper
// pattern would switch the water off entirely.
#define BUSY_LO     0.06
#define BUSY_HI     0.30

// ── Clicks ───────────────────────────────────────────────────────────────
// The strength of the ripple spreading from where you pressed. 0 removes it.
//
// The same shape as ripples() in ../crt/crt.frag, and a different meaning. There the ring
// was **brightness**; here it is **gradient** — a stone thrown into water does not glow, it
// displaces. So the ring's cross-section is not used directly but its derivative, and the
// sign flips inside and out, so the front and back of the ring displace opposite ways. That
// is what a real ripple does.
#define CLICK       0.45              // @0..1 !motion

#define CLICK_SEC   1.6               // seconds for a ring to fade out
#define CLICK_MAX   0.45              // the radius it grows to by then (relative to screen height)
#define CLICK_W     0.06              // ring thickness. Unlike the radius, it does not grow.
#define CLICK_TAPS  8                 // no reason to walk all 32 of the history. A constant.

// ── Colour ───────────────────────────────────────────────────────────────
// How much water tint is mixed in. Past 0.6 the screen does not turn blue; it disappears.
#define TINT_MIX    0.14              // @0..0.6

// The water colour. Not a knob — a vec3 does not fit in one uniform (Sources/Knobs.swift).
// To change the colour, edit this line and save (hot reload).
#define TINT        vec3(0.42, 0.72, 0.92)

// Sun glitter. Only where the gradient tilts toward the light. Larger TIGHT is narrower and sharper.
#define SHINE       0.18              // @0..1
#define SHINE_TIGHT 24.0              // @2..80

// The light direction. z points out of the screen and y is positive downward (v_texcoord has
// a top-left origin), so this is light from the upper left.
#define LIGHT       normalize(vec3(-0.30, -0.42, 1.0))

// Puts back what refraction and glint cut away. 1.0 leaves it alone.
#define BRIGHTNESS  1.02              // @0.6..1.4


vec2 aspect() {
    return vec2(screen_size.x / screen_size.y, 1.0);
}

// One layer. Returns (height, gradient x, gradient y) together. The gradient is analytic,
// so no extra samples are needed — this function is the "four sines" from the header.
vec3 wave(vec2 p, vec2 k, float speed, float amp, float t) {
    float ph = dot(p, k) + t * speed;
    return vec3(amp * sin(ph), amp * k * cos(ph));
}

// Four ripple layers. The wave numbers are not integer multiples of each other, and two are
// set nearly head-on — two opposing waves are what make the shimmer you see on still water.
vec3 ripples(vec2 p, float t) {
    return wave(p, vec2( 1.00,  0.31), 1.00, 1.00, t)
         + wave(p, vec2(-0.83,  0.55), 0.83, 0.72, t)
         + wave(p, vec2( 0.47, -1.13), 1.31, 0.38 * CHOP, t)
         + wave(p, vec2(-1.29, -0.71), 1.67, 0.24 * CHOP, t);
}

// The summed gradient recent clicks leave on this pixel. 0 means nothing is happening.
vec2 clickSlope(vec2 uv) {
    vec2 acc = vec2(0.0);
    vec2 a   = aspect();

    for (int i = 0; i < CLICK_TAPS; i++) {
        float age = pointer_pressed_times[i];
        // A slot never clicked carries the time since launch, which is very large. So this
        // one line filters it out with no separate "empty" marker (the same reason as the
        // same place in ../crt/crt.frag).
        if (age > CLICK_SEC) continue;

        float k = age / CLICK_SEC;                  // 0 → 1
        vec2  d = (uv - pointer_pressed_positions[i]) * a;
        float r = length(d) + 1e-4;                 // guards the divide by zero at the centre
        float e = (r - k * CLICK_MAX) / CLICK_W;

        // The ring's cross-section is exp(-e²), so the gradient is its derivative,
        // -2e·exp(-e²). The 1/CLICK_W is deliberately left off — with it, shrinking CLICK_W
        // would blow up the gradient along with it and CLICK would lose its meaning. What is
        // needed here is the ring's **shape**, not a physically correct magnitude.
        acc += (d / r) * (-2.0 * e * exp(-e * e)) * (1.0 - k) * CLICK;
    }
    return acc;
}

// How crowded with small text this spot is. 0 is quiet, 1 is text.
//
// **The mean, not the maximum.** Measured by maximum, one high-contrast edge would give 1
// and the water would switch off on window borders and wallpaper patterns alike. The mean
// catches only "places that change often", so it fills on text and icon fields alone.
//
// The taps are a spiral for the same reason as bloom() in ../crt/crt.frag — going around in
// rings leaves grain, one point per direction, and a spiral does not.
float busy(vec2 uv, vec2 px) {
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    float c = dot(texture(tex, uv).rgb, W);
    float e = 0.0;
    for (int i = 0; i < BUSY_TAPS; i++) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(BUSY_TAPS));
        float a  = fi * 2.39996323;                 // golden angle
        vec2  o  = vec2(cos(a), sin(a)) * r * PRESERVE_PX * px;
        e += abs(dot(texture(tex, uv + o).rgb, W) - c);
    }
    return smoothstep(BUSY_LO, BUSY_HI, e / float(BUSY_TAPS));
}

void main() {
    vec2 px = 1.0 / screen_size;
    vec2 uv = v_texcoord;

    vec3  s = ripples(uv * aspect() * RIPPLE, time * SPEED);
    vec2  g = s.yz + clickSlope(uv);

    // Fold the displacement at the edges. The clampToEdge measure from the header.
    vec2  f = smoothstep(0.0, EDGE_FADE, uv) * smoothstep(0.0, EDGE_FADE, 1.0 - uv);
    float fade = f.x * f.y;

    // Fold it where text is, too. With PRESERVE at 0 the taps are not sampled at all — the
    // branch turns on a single uniform, so the whole warp goes the same way and it costs nothing.
    if (PRESERVE > 0.001) fade *= 1.0 - busy(uv, px) * PRESERVE;

    vec2 off = -g * REFRACT * px * fade;
    vec3 col = texture(tex, uv + off).rgb;

    // The water tint. Unlike the displacement, it is applied at the edges too — it reads
    // nothing outside, so there is no reason to fold it, and folding would leave only the
    // border looking unlike water.
    col = mix(col, col * TINT * 1.35, TINT_MIX);

    // Sun glitter. Stand the gradient up as a normal and put it against the light. Even on
    // flat water it leaves not 0 but a very small value (the dot product is 0.89, and 0.89
    // to the 24th is 0.06), and that becomes the faint sheen lying over the whole surface.
    vec3 n = normalize(vec3(-g, 1.0));
    col += SHINE * pow(max(dot(n, LIGHT), 0.0), SHINE_TIGHT);

    col *= BRIGHTNESS;

    // The overlay layer is opaque, so alpha is discarded (Sources/Renderer.swift). Under
    // Hyprland a screen shader's result also goes straight to the framebuffer, so 1 is right.
    fragColor = vec4(col, 1.0);
}
