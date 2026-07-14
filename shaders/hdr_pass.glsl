#version 300 es
/**
 * ══════════════════════════════════════════════════════════════════════════════
 *  PASS 1: HDR EXPANSION (SDR → HDR)
 * ══════════════════════════════════════════════════════════════════════════════
 * 
 * Intent:
 * Standard SDR images are clamped between [0.0, 1.0]. To simulate how they would
 * look on an HDR display (which has much higher peak brightness), this shader
 * mathematically expands the highlights beyond 1.0. 
 * 
 * Flow:
 * 1. Convert input sRGB (BT.709) into BT.2020 wide color gamut.
 * 2. Calculate pixel luminance.
 * 3. Lift shadows (below u_shadowPivot) slightly for better visibility.
 * 4. Expand highlights (above u_highlightPivot) using an Inverse Reinhard
 *    curve. This allows values to gracefully stretch out to infinity instead
 *    of clipping.
 * 5. Render to an RGBA16F (16-bit float) buffer to physically store these
 *    super-bright values (e.g., 2.5, 4.0, etc.) without losing data.
 */
precision highp float;

uniform vec2 u_resolution;
uniform vec2 u_imageResolution;
uniform float u_time;
uniform sampler2D u_texture;

out vec4 outColor;

// ─── Color Space ───
vec3 bt709_to_bt2020(vec3 c) {
    return vec3(
        dot(c, vec3(0.6274, 0.3293, 0.0433)),
        dot(c, vec3(0.0691, 0.9195, 0.0114)),
        dot(c, vec3(0.0164, 0.0880, 0.8956))
    );
}

uniform float u_shadowPivot;
uniform float u_shadowGain;
uniform float u_highlightPivot;
uniform float u_highlightStrength;
uniform bool u_exportMode;

// ─── Perceptual Luma Gain ───
float computeLumaGain(float luma) {
    float maxHeadroom = 10.0; // Increased ceiling to allow much more dramatic expansion

    if (luma < u_shadowPivot) {
        float t = smoothstep(0.0, u_shadowPivot, luma);
        return mix(u_shadowGain, 1.0, t);
    }
    if (luma < u_highlightPivot) return 1.0;

    float normalized = (luma - u_highlightPivot) / max(1.0 - u_highlightPivot, 0.0001);
    float expanded = normalized / max(1.0 - u_highlightStrength * normalized, 0.0001);
    float expandedLuma = u_highlightPivot + expanded * (1.0 - u_highlightPivot);

    float t = smoothstep(u_highlightPivot, maxHeadroom, expandedLuma);
    float ceilLuma = mix(expandedLuma, maxHeadroom, t * t);

    return ceilLuma / max(luma, 0.0001);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution.xy;
    bool isMobile = u_resolution.x < 768.0;
    
    // ─── Grid Layout & Aspect Ratio ───
    vec2 localQuadUV;
    vec2 quadRes;
    int panelIndex = 0;

    if (u_exportMode) {
        // Render only Panel 2 (ACES Tonemapped HDR) fullscreen
        localQuadUV = uv;
        quadRes = u_resolution;
        panelIndex = 2;
    } else if (isMobile) {
        // 1x4 Vertical Grid (4 rows, 1 col)
        localQuadUV = vec2(uv.x, fract(uv.y * 4.0));
        quadRes = vec2(u_resolution.x, u_resolution.y * 0.25);
        
        // WebGL y=1 is top, y=0 is bottom
        if (uv.y > 0.75)      panelIndex = 0; // 1st (Top): SDR
        else if (uv.y > 0.5)  panelIndex = 1; // 2nd: Naïve Boost
        else if (uv.y > 0.25) panelIndex = 3; // 3rd: Luma Analysis
        else                  panelIndex = 2; // 4th (Bottom): ACES HDR
    } else {
        // 2x2 Grid Layout
        localQuadUV = fract(uv * 2.0);
        quadRes = u_resolution * 0.5;
        
        if (uv.x < 0.5 && uv.y > 0.5)       panelIndex = 0; // Top-Left: SDR
        else if (uv.x >= 0.5 && uv.y > 0.5) panelIndex = 1; // Top-Right: Naïve Boost
        else if (uv.x < 0.5 && uv.y <= 0.5) panelIndex = 2; // Bottom-Left: ACES HDR
        else                                panelIndex = 3; // Bottom-Right: Luma Analysis
    }

    // Prevent div-by-zero before image loads
    float quadAspect = quadRes.x / quadRes.y;
    float imgAspect = max(u_imageResolution.x, 1.0) / max(u_imageResolution.y, 1.0);

    vec2 targetUV = localQuadUV * 2.0 - 1.0; // -1..1
    if (quadAspect > imgAspect) {
        // Pillarbox
        targetUV.x *= quadAspect / imgAspect;
    } else {
        // Letterbox
        targetUV.y *= imgAspect / quadAspect;
    }
    targetUV = targetUV * 0.5 + 0.5; // 0..1
    
    // Check if outside image bounds (letterbox/pillarbox black bars)
    if (targetUV.x < 0.0 || targetUV.x > 1.0 || targetUV.y < 0.0 || targetUV.y > 1.0) {
        // alpha = 0.0 tells display_pass to render absolute black
        outColor = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    // WebGL textures are Y-flipped
    targetUV.y = 1.0 - targetUV.y;
    vec3 inputRGB = texture(u_texture, targetUV).rgb;

    // ─── Panel Logic ───
    if (panelIndex == 0) {
        // Panel 0: SDR Original
        outColor = vec4(inputRGB, 1.0);
    } 
    else if (panelIndex == 1) {
        // Panel 1: Raw HDR Expansion (No tonemap, gets clipped by monitor)
        vec3 bt2020 = bt709_to_bt2020(inputRGB);
        float luma = dot(bt2020, vec3(0.2627, 0.6780, 0.0593));
        float gain = computeLumaGain(luma);
        vec3 hdrLinear = bt2020 * gain;
        outColor = vec4(hdrLinear, 1.0); // alpha 1.0 signals NO tonemap to display pass
    } 
    else if (panelIndex == 2) {
        // Panel 2: Perceptual HDR (ACES)
        vec3 bt2020 = bt709_to_bt2020(inputRGB);
        float luma = dot(bt2020, vec3(0.2627, 0.6780, 0.0593));
        float gain = computeLumaGain(luma);
        vec3 hdrLinear = bt2020 * gain;
        outColor = vec4(max(hdrLinear, 0.0), 0.75); // 0.75 alpha signals ACES tonemap to display pass
    } 
    else if (panelIndex == 3) {
        // Panel 3: Luma Analysis
        vec3 bt2020 = bt709_to_bt2020(inputRGB);
        float luma = dot(bt2020, vec3(0.2627, 0.6780, 0.0593));
        if (luma >= u_highlightPivot) {
            outColor = vec4(0.0, 1.0, 0.0, 0.5);    // Highlights (above pivot): green
        } else if (luma <= u_shadowPivot) {
            outColor = vec4(0.0, 0.5, 1.0, 0.5);    // Shadows (below pivot): blue
        } else {
            outColor = vec4(vec3(luma), 0.5);         // Midtones: gray
        }
    }

    // ─── Grid Dividers ───
    // Very thin dividers (1 pixel width)
    vec2 px = 1.0 / u_resolution;
    if (!u_exportMode) {
        if (isMobile) {
            if (abs(uv.y - 0.75) < px.y || abs(uv.y - 0.5) < px.y || abs(uv.y - 0.25) < px.y) {
                outColor = vec4(0.0, 0.0, 0.0, 0.0);
            }
        } else {
            if (abs(uv.x - 0.5) < px.x || abs(uv.y - 0.5) < px.y) {
                outColor = vec4(0.0, 0.0, 0.0, 0.0);
            }
        }
    }
}
