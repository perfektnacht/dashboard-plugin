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
    float warp;          //  68
    float scanline;      //  72
    float scanPeriod;    //  76
    float maskStrength;  //  80
    float vignette;      //  84
    float glow;          //  88
    float aberration;    //  92
    float tintAmount;    //  96
    float glassCorner;   // 100
    // Corner radius of the housing itself, in physical pixels rather than as a
    // fraction: a moulded corner has a radius, and a fraction of a panel that
    // isn't square would draw a quarter-ellipse instead.
    float outerCorner;   // 104
    // Unsharp amount. Sits at 108 because bezel needs 8-byte alignment and so
    // starts at 112 either way — this dial is free, occupying padding that was
    // already being paid for.
    float sharpen;       // 108
    // A vec2, not a scalar: UV is normalised per axis, so one number would
    // make the frame thicker on the long side of a panel that isn't square.
    vec2 bezel;          // 112
    vec2 resolution;     // 120
    vec4 tint;           // 128
    vec4 bezelTint;      // 144
    // Floor the phosphor bleed has to clear before it lights anything.
    float bloomThreshold; // 160
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

// Signed distance to a rounded rectangle, negative inside. The glass gets its
// corners from this rather than from the barrel warp alone: warp bends the
// edges but still meets in a hard point at each corner, and a hard point is
// the one thing no picture tube has.
float roundedBox(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// A cheap 8-tap ring, which is to say a low-pass of the neighbourhood. It feeds
// two stages that want opposite things from it: the phosphor bleed adds it, and
// the unsharp mask subtracts it. Both read the same taps, so the sharpening
// costs no texture fetches at all.
vec3 lowPass(vec2 uv, vec2 texel) {
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

    // The housing's outside edge. The glass has been rounded since the start
    // and the plastic around it had not, which left the one square corner in a
    // panel whose own border is already curved — read as a hard grey box sat
    // inside a rounded window. Measured in pixels on the unwarped coordinates:
    // this is the moulding, so it does not bow with the tube.
    vec2 halfPanel = resolution * 0.5;
    float outerRadius = min(outerCorner, min(halfPanel.x, halfPanel.y));
    float outerDist = roundedBox((qt_TexCoord0 - 0.5) * resolution,
                                 halfPanel, outerRadius);
    float outerAA = max(fwidth(outerDist), 1e-5);
    // Alpha, not a colour: what shows through the corner is the panel's own
    // background, the same as the margin already visible around the frame.
    float inPanel = 1.0 - smoothstep(-outerAA, outerAA, outerDist);

    // Past the glass there is nothing to sample, and sampling anyway would
    // smear the edge texel across the whole frame.
    if (inGlass <= 0.0) {
        fragColor = vec4(frame, 1.0) * qt_Opacity * inPanel;
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

    vec3 blurred = lowPass(texUV, texel);

    // Unsharp mask, before anything else touches the colour. The barrel warp
    // lands almost every pixel on a fractional texel, so the bilinear filter
    // has already softened the whole image by the time it gets here — this is
    // not a stylistic sharpen, it is putting back what the resample took.
    // Clamped at zero because the undershoot on the dark side of a glyph edge
    // would otherwise go negative and show up as a black rim once the tint
    // multiplies it back up.
    color = max(color + (color - blurred) * sharpen, vec3(0.0));

    // Phosphor bleed, from the lit phosphors only. Adding the low-pass
    // unconditionally spread the dark gaps between glyphs just as eagerly as
    // the glyphs themselves, which is a box blur wearing a glow's name: the
    // text lost its edge and the background never got brighter for it. With a
    // floor under it, only what is actually emitting light spreads.
    color += max(blurred - bloomThreshold, vec3(0.0)) * glow;

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

    // There was a mains-hum stage here — a slow brightness wobble and a band
    // rolling up the screen. It was removed rather than dialled down: nobody
    // could see it, and it was the one thing in the effect that varied with
    // time, so it alone forced a repaint every single frame the panel was
    // open. Everything left is a pure function of position, which is what lets
    // an open panel sit at zero GPU load instead of at a steady drain.
    //
    // Vignette, on the warped coordinates so it follows the bowed edge.
    vec2 v = uv * (1.0 - uv.yx);
    float vig = pow(v.x * v.y * 22.0, vignette * 0.6);
    color *= clamp(vig, 0.0, 1.0);

    // Blend glass into frame across the antialiased edge. Opaque everywhere
    // inside the housing: the frame is a physical object and the tube behind it
    // isn't a window, so neither has any business letting the desktop through.
    // The only transparency is outside the rounded corners, where the panel
    // behind shows instead. Premultiplied, which is what the scene graph wants.
    fragColor = vec4(mix(frame, color, inGlass), 1.0) * qt_Opacity * inPanel;
}
