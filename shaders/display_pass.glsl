#version 300 es
/**
 * ══════════════════════════════════════════════════════════════════════════════
 *  PASS 2: DISPLAY MAPPING (Tonemapping HDR → SDR)
 * ══════════════════════════════════════════════════════════════════════════════
 * 
 * Intent:
 * The output from Pass 1 is an RGBA16F buffer where pixels might exceed 1.0 
 * (e.g. up to 4.0). Since standard web monitors cannot display values > 1.0, we 
 * must gracefully compress this HDR data back into an SDR range [0.0, 1.0].
 * 
 * Flow:
 * 1. Read the high-dynamic-range pixels from the float buffer.
 * 2. If the pixel is marked as ACES (Panel 2), apply an ACES Filmic tonemap 
 *    curve. This acts like a camera sensor, rolling off the super-bright values 
 *    smoothly to preserve contrast and prevent harsh clipping.
 * 3. Tonemap only the luminance (brightness) while scaling the RGB color ratio 
 *    proportionally. This prevents the "hue shift" artifact where bright colors 
 *    desaturate into white.
 * 4. Convert back to BT.709 (sRGB) for display.
 */
precision highp float;

uniform vec2 u_resolution;
uniform sampler2D u_hdrBuffer;

out vec4 outColor;

// ═══════════════════════════════════════
//  Transfer Functions & Tonemapping
// ═══════════════════════════════════════

// ─── sRGB OETF ───
vec3 linear_to_srgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// ─── ACES Filmic Tonemap ───
// Smoothly maps [0, ∞) to [0, 1] while preserving contrast and saturation.
vec3 aces_tonemap(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// ═══════════════════════════════════════
//  Gamut Conversion
// ═══════════════════════════════════════

// ─── BT.2020 → BT.709 ───
// Converts the expanded BT.2020 HDR data back to the monitor's native sRGB gamut
// so the colors don't look washed out.
vec3 bt2020_to_bt709(vec3 c) {
    return vec3(
        dot(c, vec3( 1.6605, -0.5877, -0.0728)),
        dot(c, vec3(-0.1246,  1.1330, -0.0084)),
        dot(c, vec3(-0.0182, -0.1006,  1.1187))
    );
}

// ═══════════════════════════════════════
//  Main
// ═══════════════════════════════════════

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution.xy;
    vec4 hdr = texture(u_hdrBuffer, uv);

    if (hdr.a < 0.25) {
        // ── Divider ──
        outColor = vec4(0.0, 0.0, 0.0, 1.0);

    } else if (hdr.a < 0.625) {
        // ── Display-ready (Panel 4: Luma Analysis) ──
        outColor = vec4(hdr.rgb, 1.0);

    } else if (hdr.a < 0.875) {
        // ── Panel 3: Perceptual HDR (Inverse Reinhard + ACES) ──
        // 1. Convert the BT.2020 HDR headroom back to BT.709 primaries
        vec3 bt709Linear = bt2020_to_bt709(hdr.rgb);
        
        // 2. Fix Hue Rotation: Apply ACES only to the luminance.
        //    Tonemapping RGB independently changes their ratios, causing hue shifts.
        //    Instead, we tonemap the luma and scale the RGB channels evenly.
        float lumaIn = dot(bt709Linear, vec3(0.2627, 0.6780, 0.0593));
        float lumaOut = aces_tonemap(vec3(lumaIn)).x;
        
        float scale = (lumaIn > 0.0001) ? (lumaOut / lumaIn) : 0.0;
        vec3 tonemapped = bt709Linear * scale;
        
        // 3. Apply sRGB gamma for the display
        outColor = vec4(linear_to_srgb(tonemapped), 1.0);

    } else {
        // ── BT.709 sRGB (Panel 1: SDR, Panel 2: Naïve Boost) ──
        outColor = vec4(linear_to_srgb(clamp(hdr.rgb, 0.0, 1.0)), 1.0);
    }
}
