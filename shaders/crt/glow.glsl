// glow.glsl — phosphor afterglow alone. What is worth running every day from crt.frag.
//
// So it shares the same origin — Maxim Samoliuk's Hyprland screen shader (MIT) from the
// space_dots (Golden Era) rice. The details are in the header of ./crt.frag and ../../LICENSE.
//
// No curvature, no chromatic aberration, no grille. Text blooms slightly and a very shallow
// scanline lies over it, so body text stays as readable as it was. It does not use iTime,
// so redraw stays off — it draws only when the screen changes.
//
// What is kept has to work the same way crt.frag does: a golden-angle spiral with a soft
// knee, not an 8-direction ring with a hard threshold. A ring leaves a star-shaped grain
// around bright text, one point per direction, and a hard threshold makes the bloom jump
// with glyph weight. There is no way to share code between the two files (each is an
// independent program); think of crt.frag as the original.

#define TAU 6.2831853

#define BLOOM       0.70              // @0..1.5
#define BLOOM_PX    6.0               // @1..16
#define BLOOM_CUT   0.30              // @0..1
#define BLOOM_KNEE  0.28              // @0.01..0.6

// At 3 pixels a period holds only three samples and turns to moiré. 4, as in crt.frag.
#define SCAN_PX     4.0               // @2..8
#define SCAN_DEPTH  0.08              // @0..0.5

#define BRIGHTNESS  1.06              // @0.6..1.8

// Golden-angle spiral, 16 taps. Taking the radius as sqrt spreads samples evenly over the area.
vec3 bloom(vec2 uv, vec2 px) {
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 16; i++) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / 16.0);
        float a  = fi * 2.39996323;          // golden angle
        float w  = exp(-r * r * 1.8);        // Gaussian weight
        vec3  c  = texture(iChannel0, uv + vec2(cos(a), sin(a)) * r * BLOOM_PX * px).rgb;
        float l  = dot(c, vec3(0.2126, 0.7152, 0.0722));
        sum  += c * smoothstep(BLOOM_CUT, BLOOM_CUT + BLOOM_KNEE, l) * w;
        wsum += w;
    }
    return sum / wsum;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 px = 1.0 / iResolution.xy;
    vec2 uv = fragCoord * px;

    vec4 src = texture(iChannel0, uv);
    vec3 col = src.rgb + bloom(uv, px) * BLOOM;

    col *= 1.0 - SCAN_DEPTH * (0.5 + 0.5 * sin(fragCoord.y * TAU / SCAN_PX));
    col *= BRIGHTNESS;

    // Unlike crt, alpha is kept. Nothing is cut out of a window here, so background
    // transparency has to pass through.
    fragColor = vec4(col, src.a);
}
