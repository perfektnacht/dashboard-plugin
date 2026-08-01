#version 440

// CRT / phosphor-terminal effect for a Quickshell panel.
//
// Built as one shader with every stage on a dial rather than as three separate
// shaders, so the same compiled artifact covers "barely there" and "Pip-Boy"
// and everything between — the look is chosen by the QML, not by the build.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// std140: the mat4 lands at 0, the scalars pack from 64, and the vec2/vec4 are
// placed on their own alignment boundaries (8 and 16). Get this wrong and the
// values silently arrive in the wrong slots.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;      //   0
    float qt_Opacity;    //  64
    float time;          //  68
    float warp;          //  72
    float scanline;      //  76
    float scanPeriod;    //  80
    float maskStrength;  //  84
    float vignette;      //  88
    float glow;          //  92
    float aberration;    //  96
    float tintAmount;    // 100
    float flicker;       // 104
    float glassCorner;   // 108
    // A vec2, not a scalar: UV is normalised per axis, so one number would
    // make the frame thicker on the long side of a panel that isn't square.
    vec2 bezel;          // 112
    vec2 resolution;     // 120
    vec4 tint;           // 128
    vec4 bezelTint;      // 144
};

layout(binding = 1) uniform sampler2D source;

// Barrel distortion: push each coordinate outward by the square of its
// distance on the other axis, which is what makes the corners bow the way a
// real tube's glass does. The 6/4 split is the traditional cheat for a screen
// wider than it is tall — the horizontal curve reads as weaker than vertical.
vec2 curve(vec2 uv, float amount) {
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) / vec2(6.0, 4.0);
    uv += uv * offset * offset * amount;
    return uv * 0.5 + 0.5;
}

// A cheap 8-tap bloom. A real CRT's phosphors bleed into their neighbours, and
// without it the scanlines just look like a dark grid laid over a sharp image
// rather than like light spreading through glass.
// Signed distance to a rounded rectangle, negative inside. The glass gets its
// corners from this rather than from the barrel warp alone: warp bends the
// edges but still meets in a hard point at each corner, and a hard point is
// the one thing no picture tube has.
float roundedBox(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vec3 bloom(vec2 uv, vec2 texel) {
    vec3 sum = vec3(0.0);
    sum += texture(source, uv + texel * vec2(-1.0, -1.0)).rgb;
    sum += texture(source, uv + texel * vec2( 0.0, -1.5)).rgb;
    sum += texture(source, uv + texel * vec2( 1.0, -1.0)).rgb;
    sum += texture(source, uv + texel * vec2(-1.5,  0.0)).rgb;
    sum += texture(source, uv + texel * vec2( 1.5,  0.0)).rgb;
    sum += texture(source, uv + texel * vec2(-1.0,  1.0)).rgb;
    sum += texture(source, uv + texel * vec2( 0.0,  1.5)).rgb;
    sum += texture(source, uv + texel * vec2( 1.0,  1.0)).rgb;
    return sum / 8.0;
}

void main() {
    vec2 texel = 1.0 / resolution;

    // The glass sits inside the panel, inset by `bezel` on every side. The QML
    // lays the content out inside that same inset, so this maps the frame onto
    // empty margin rather than cropping anything.
    vec2 glassMin = bezel;
    vec2 glassMax = vec2(1.0) - bezel;
    vec2 g = (qt_TexCoord0 - glassMin) / max(glassMax - glassMin, vec2(0.0001));

    vec2 uv = curve(g, warp);

    // Distance to the glass edge, in glass space, positive inside. fwidth
    // gives one pixel's worth of it, which is what turns the old hard cutoff —
    // a stair-stepped black outline — into a clean antialiased edge.
    float dist = -roundedBox(uv * 2.0 - 1.0, vec2(1.0), glassCorner);
    float aa = max(fwidth(dist), 1e-5);
    float inGlass = smoothstep(-aa, aa, dist);

    // A moulded frame rather than a flat black surround: a soft vertical
    // gradient reads as plastic catching the room light, and the darkening in
    // the last few pixels before the glass is the shadow the lip casts on the
    // tube. Both are what make it look like a monitor instead of a hole.
    vec3 frame = bezelTint.rgb * (1.08 - 0.22 * qt_TexCoord0.y);
    frame *= mix(0.55, 1.0, smoothstep(-0.10, 0.02, -dist));

    // Past the glass there is nothing to sample, and sampling anyway would
    // smear the edge texel across the whole frame.
    if (inGlass <= 0.0) {
        fragColor = vec4(frame, 1.0) * qt_Opacity;
        return;
    }

    uv = clamp(uv, vec2(0.0), vec2(1.0));
    // Back into texture space, since the content lives inside the inset.
    vec2 texUV = glassMin + uv * (glassMax - glassMin);

    // Chromatic aberration, scaled by distance from the centre: a tube's
    // convergence is fine in the middle and drifts at the corners, so a
    // uniform split reads as a printing error instead of as glass.
    vec2 fromCenter = uv - 0.5;
    float edge = dot(fromCenter, fromCenter);
    vec2 shift = fromCenter * edge * aberration * texel.x * 6.0;

    vec3 color;
    color.r = texture(source, texUV + shift).r;
    color.g = texture(source, texUV).g;
    color.b = texture(source, texUV - shift).b;

    color += bloom(texUV, texel) * glow;

    // Phosphor tint. Luminance first, so the tint replaces the hue rather than
    // washing over it — the difference between a green screen and a green
    // filter taped to a colour one.
    float luma = dot(color, vec3(0.299, 0.587, 0.114));
    color = mix(color, tint.rgb * luma * 1.35, tintAmount);

    // Scanlines, locked to output pixels rather than to UV so they stay a fixed
    // number of physical lines apart instead of scaling with the panel. A
    // one-pixel period would alias into a grey wash on any non-integer scale,
    // so the period is a dial and wants to be 2 or 3.
    // Driven from the panel coordinate, not the glass one, so the spacing is a
    // fixed number of screen pixels and doesn't change when the bezel does.
    float line = sin(qt_TexCoord0.y * resolution.y * 3.14159265 / max(scanPeriod, 1.0));
    color *= 1.0 - scanline * (1.0 - line * line);

    // Aperture grille: each column of pixels leans toward one phosphor. Kept
    // subtle by default — at this size a full mask eats a third of the light.
    float m = mod(floor(qt_TexCoord0.x * resolution.x), 3.0);
    vec3 maskTint = vec3(1.0 - maskStrength);
    if (m < 1.0)      maskTint.r = 1.0 + maskStrength * 0.5;
    else if (m < 2.0) maskTint.g = 1.0 + maskStrength * 0.5;
    else              maskTint.b = 1.0 + maskStrength * 0.5;
    color *= maskTint;

    // Mains hum: a slow brightness wobble plus a bright band rolling up the
    // screen, which is the thing that most reads as "this is a live tube"
    // rather than "this is a picture of one".
    float roll = sin((uv.y + time * 0.15) * 6.28318) * 0.5 + 0.5;
    color *= 1.0 + flicker * (0.015 * sin(time * 6.0) + 0.02 * pow(roll, 8.0));

    // Vignette, on the warped coordinates so it follows the bowed edge.
    vec2 v = uv * (1.0 - uv.yx);
    float vig = pow(v.x * v.y * 22.0, vignette * 0.6);
    color *= clamp(vig, 0.0, 1.0);

    // Blend glass into frame across the antialiased edge. Opaque throughout:
    // the frame is a physical object and the tube behind it isn't a window, so
    // neither has any business letting the desktop through.
    fragColor = vec4(mix(frame, color, inGlass), 1.0) * qt_Opacity;
}
