#version 300 es
//
// paper.frag — e-ink. Turns the screen into paper. A look made for reading.
//
// It does not read time, so redraw stays off. That axis is covered in
// ../../docs/knobs.md, "The shader decides whether to keep drawing".
//
// ── Alone in its family ──────────────────────────────────────────────────
// Where other looks trade legibility for style, this one goes the other way — it is applied
// **in order to read**, and every other decision leans toward legibility. Smearing small
// text is a failure here.
//
// That difference comes out as SHARP below. Most shaders move toward blur (bloom, focus,
// haze); this one alone **sharpens**. Desaturation and tonal compression make strokes look
// soft, and without putting that back it is a faded screen rather than paper.
//
// ── Why not just greyscale ───────────────────────────────────────────────
// Taking the saturation out gives a grey screen, not paper. Three things make it read as paper.
//
// **One. White is not white.** The white of paper is about 0.93 rather than 1.0, and it is
// slightly warm. Pure white left alone reads as a screen emitting light.
//
// **Two. Black is not black.** The black of ink is about 0.12 rather than 0.0. At 0 this is
// OLED, not e-ink.
//
// **Three. It has grain.** The very faint mottle of paper fibre. Time does not enter into
// it, so it is fixed per screen position, which means the paper is attached to the screen —
// move a window and the grain stays put. A real e-reader is like that.
//
// ── Layering ─────────────────────────────────────────────────────────────
// Applied alone is right. Whatever comes before it, the colour and light it produced are
// taken back out here, so it costs more for the same result. If layered anyway, a very light
// ../cyberpunk/glitch.frag after it (DENSITY 0.03) gives "an ageing e-reader".

precision highp float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;

// ── Desaturation ─────────────────────────────────────────────────────────
// How far colour is removed. 1 is fully greyscale. The default is 0.9 because syntax
// highlighting surviving even faintly is better for reading code — removed entirely,
// comments and strings become the same grey.
#define GRAY        0.90              // @0..1

// ── Ink and paper ────────────────────────────────────────────────────────
// The white of paper and the black of ink — the two from the header. Between them is linear.
#define PAPER       0.93              // @0.6..1
#define INK         0.12              // @0..0.4

// The warmth of the paper. A vec3 cannot be a knob; edit and save and it applies immediately.
#define PAPER_TINT  vec3(1.00, 0.98, 0.93)

// Contrast. The tonal range was narrowed, so the middle has to be stood up for text to
// separate from the background. A pow exponent, so 1.0 leaves it alone.
#define CONTRAST    1.18              // @0.5..2.5

// ── Edge ─────────────────────────────────────────────────────────────────
// Unsharp mask strength. The difference from the average of the four neighbours is added
// back — as the header says, this file alone goes the opposite way from blur.
//
// Past 0.8 a white fringe starts to show around the text. In print that is called an unsharp
// halo; a little of it actually reads as sharper, but too much shows.
#define SHARP       0.45              // @0..1.5

// The radius the edge is built over, in pixels. 1 is close to the stroke weight of body
// text. Larger and the fringe lands on window borders rather than glyphs.
#define SHARP_PX    1.0               // @0.5..4

// ── Grain ────────────────────────────────────────────────────────────────
// The mottle of paper fibre. Two layers, so it is clumped grain rather than a single-layer
// speckle — one layer reads as screen noise, two read as paper.
#define FIBER       0.030             // @0..0.12

// The coarseness of the grain, in pixels. Near 1 this is noise, not fibre.
#define FIBER_PX    3.0               // @1..12

// A very faint edge shadow. What the glass and bezel of an e-reader make.
#define SHADE       0.06              // @0..0.3


float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// One layer of value noise. Paper grain needs no gradient, so only the value is returned
// (the version that returns the gradient too is noised() in ../water/river.frag).
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i),               hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec2 px  = 1.0 / screen_size;
    vec2 uv  = v_texcoord;
    vec2 pix = uv * screen_size;

    vec3 src = texture(tex, uv).rgb;

    // Unsharp mask. Brighter than the average of the four neighbours goes brighter, darker
    // goes darker. Applied **before** desaturation so colour boundaries sharpen too.
    vec2 r = SHARP_PX * px;
    vec3 avg = (texture(tex, uv + vec2( r.x, 0.0)).rgb
              + texture(tex, uv + vec2(-r.x, 0.0)).rgb
              + texture(tex, uv + vec2(0.0,  r.y)).rgb
              + texture(tex, uv + vec2(0.0, -r.y)).rgb) * 0.25;
    vec3 c = src + (src - avg) * SHARP;

    // Desaturation.
    c = mix(c, vec3(luma(c)), GRAY);

    // Stand the contrast up, then fold into the range between ink and paper. The other way
    // round would apply pow to an already narrowed range and amount to doing nothing.
    c = pow(clamp(c, 0.0, 1.0), vec3(CONTRAST));
    c = mix(vec3(INK), vec3(PAPER), c);

    // The paper colour. Weighted by brightness, so the ink barely tints and only the white warms.
    c *= mix(vec3(1.0), PAPER_TINT, luma(c));

    // Two layers of grain. Fixed per position, so it does not change while the screen does not.
    float fib = vnoise(pix / FIBER_PX) * 0.65
              + vnoise(pix / (FIBER_PX * 2.7)) * 0.35;
    c *= 1.0 - FIBER * (fib - 0.5) * 2.0;

    // The edge shadow.
    vec2 e = uv * (1.0 - uv);
    c *= 1.0 - SHADE * (1.0 - smoothstep(0.0, 0.06, min(e.x, e.y)));

    fragColor = vec4(c, 1.0);
}
