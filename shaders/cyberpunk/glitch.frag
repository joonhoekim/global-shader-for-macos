#version 300 es
//
// glitch.frag — an occasional burst of signal error. Datamosh and RGB split.
//
// ── Nothing must happen most of the time ─────────────────────────────────
// The one hard decision in this file. A screen that hisses continuously is tiresome after 3
// seconds and unusable after 30. What actually registers is **being fine and then bursting
// once**, so time is cut into slots and a die is rolled per slot.
//
//   tick = floor(time * RATE)     this slot's number
//   hash(tick) > 1 - DENSITY      does this slot burst
//   fract(time * RATE)            how far into the slot → decay
//
// So at DENSITY 0.12 it bursts about one slot in eight, and what bursts subsides quickly
// within the slot. What decisively separates this from shaking the amplitude with a sine or
// noise is that **the stretch where nothing happens is genuinely 0**. Without that it
// becomes "faintly hissing all the time", which is a broken screen, not an effect.
//
// ── The displacement wraps rather than clamps ────────────────────────────
// ../water/still.frag folds the displacement to 0 at the edges when a displaced uv leaves
// the screen, because clampToEdge stretches the border row into a streak.
//
// Here it wraps with fract() instead. **A displaced band continuing from the opposite side
// is what this effect is** — that is what really happens when a framebuffer is read out of
// step, and folding it would remove the displacement at the two ends of the screen alone,
// which reads as faker. There are places where the same problem takes the opposite answer.
//
// ── Layering ─────────────────────────────────────────────────────────────
// Its place is the **last slot** of a chain. It treats what the previous slots produced as
// the signal and breaks it, so anything after it would be tidying up what was broken.
//
//   global-shader shaders/cyberpunk/neon.frag shaders/cyberpunk/glitch.frag
//   global-shader shaders/print/paper.frag shaders/cyberpunk/glitch.frag  the print breaks up
//
// It reads `time`, so including this slot switches redraw on for the whole chain. The
// decision to pay that is in the act of choosing this file (see the header of ./neon.frag).

precision highp float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

uniform sampler2D tex;
uniform vec2 screen_size;
uniform float time;

// ── When it bursts ───────────────────────────────────────────────────────
// How many times a second the die is rolled. Higher is finer and more often; lower is rarer
// and longer.
#define RATE        1.0               // @0.1..24

// How many of those burst. At 1 it is always bursting and the "nothing happens" stretch from
// the header is gone — the ceiling is there to be pushed to, not because it is meant to sit there.
//
// At 0 burst() is always 0, so there is no displacement, no tear, and no brightness jump, and
// the RGB split that remains does not ride on time — nothing moves at all. Hence `!motion`
// (../../docs/knobs.md).
#define DENSITY     0.12              // @0..1:0.01 !motion

// How fast it subsides within a slot. Large hits and leaves; small drags to the end of the slot.
#define DECAY       5.0               // @0.5..16

// ── How it bursts ────────────────────────────────────────────────────────
// Number of horizontal bands. How many layers the screen is cut into to displace separately.
#define ROWS        28.0              // @4..120

// How far a band is displaced (relative to screen width). 0.08 is 8% of the screen. Larger
// than this reads as another screen cutting in rather than as something out of step.
#define SHIFT       0.055             // @0..0.3:0.005

// The proportion of bands displaced. At 1 every band moves and the screen looks combed;
// lower and only a few rows jump. A few rows jumping reads far more like an accident.
#define ROW_HIT     0.35              // @0..1

// ── RGB split ────────────────────────────────────────────────────────────
// The colour separation that is always on (pixels). That it is not 0 is this file's
// character — the screen has to look very slightly like a cheap signal even between bursts,
// so that a burst reads as having happened on the same screen.
#define SPLIT       0.8               // @0..6

// How many times that becomes during a burst.
#define SPLIT_BURST 9.0               // @1..30

// ── Tear ─────────────────────────────────────────────────────────────────
// A whole row displaced and streaming during a burst. Unlike band displacement it happens in
// one place only and is far wider. 0 removes it.
#define TEAR        0.55              // @0..1

// The thickness of the torn row (relative to screen height).
#define TEAR_H      0.035             // @0.002..0.2:0.001

// How far brightness jumps at the moment of a burst. That is what a signal cutting out does.
#define FLASH       0.18              // @0..1


float hash11(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// The strength of the accident at this instant. 0 means nothing is happening.
//
// step(), so 0 is really 0. With smoothstep, "a slot that almost did not burst" would be very
// faintly on all the time, back to the permanent hiss the header set out to avoid.
float burst(float t) {
    float tick = floor(t * RATE);
    float on   = step(1.0 - DENSITY, hash11(tick));
    float k    = fract(t * RATE);
    return on * exp(-k * DECAY);
}

void main() {
    vec2 px = 1.0 / screen_size;
    vec2 uv = v_texcoord;

    float t    = time;
    float tick = floor(t * RATE);
    float amp  = burst(t);

    // ── Band displacement ────────────────────────────────────────────────
    // The tick has to be mixed into the band number for a different band to be caught each
    // slot. Without it the same rows always jump and the screen looks like it has a broken spot.
    float row  = floor(uv.y * ROWS);
    float r1   = hash21(vec2(row, tick));
    float hit  = step(1.0 - ROW_HIT, r1);
    float dx   = (hash21(vec2(row, tick + 7.0)) - 0.5) * 2.0 * SHIFT * amp * hit;

    // ── Tear ─────────────────────────────────────────────────────────────
    // One place per slot. Falling inside the thickness displaces far further.
    float ty   = hash11(tick + 3.0);
    float tin  = step(abs(uv.y - ty), TEAR_H * 0.5);
    dx += (hash11(tick + 11.0) - 0.5) * 0.5 * TEAR * amp * tin;

    // Wrap. As the header says, joining rather than folding is what is right here.
    vec2 suv = vec2(fract(uv.x + dx), uv.y);

    // ── RGB split ────────────────────────────────────────────────────────
    float sp = SPLIT * (1.0 + (SPLIT_BURST - 1.0) * amp) * px.x;
    vec3 col = vec3(
        texture(tex, vec2(fract(suv.x + sp), suv.y)).r,
        texture(tex, suv).g,
        texture(tex, vec2(fract(suv.x - sp), suv.y)).b
    );

    // The brightness jump at the moment of a burst. Only on displaced bands, so the whole screen does not flash.
    col += FLASH * amp * (hit * 0.6 + tin);

    fragColor = vec4(col, 1.0);
}
