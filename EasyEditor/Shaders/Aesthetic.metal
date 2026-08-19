#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// Cheap hash — good enough for grain and snow, and stable per pixel.
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

extern "C" {
namespace coreimage {

/// One pass covering the per-pixel work the analogue looks need: tube
/// curvature, per-line tape wobble, head-switch tear, chroma separation,
/// scanlines, phosphor mask, grain and snow.
///
/// mode: 0 = CRT, 1 = VHS, 2 = NTSC.
float4 aestheticPass(sampler src,
                     float width, float height, float mode, float strength,
                     float time, float scanline, float bleed, float wobble,
                     float noiseAmount, float tear, float maskAmount,
                     destination dest)
{
    float w = max(width, 1.0);
    float h = max(height, 1.0);
    float2 dc = dest.coord();
    float2 uv = float2(dc.x / w, dc.y / h);
    float s = clamp(strength, 0.0, 1.0);

    // CRT: the glass bulges, and there is nothing outside it.
    if (mode < 0.5) {
        float2 c = uv * 2.0 - 1.0;
        float r2 = dot(c, c);
        c *= 1.0 + 0.055 * s * r2;
        uv = c * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    // VHS: the line never sits still, and the head switch tears the bottom.
    if (mode > 0.5 && mode < 1.5) {
        float line = uv.y * h;
        float drift = sin(line * 0.55 + time * 8.0) * 0.0009
                    + sin(line * 0.11 + time * 2.3) * 0.0024;
        uv.x += drift * wobble * s * 5.0;

        float band = 0.06 * tear;
        if (band > 0.0001 && uv.y < band) {
            float k = 1.0 - uv.y / band;
            float jitter = hash21(float2(floor(time * 11.0), 3.0));
            uv.x += k * k * (0.015 + 0.045 * jitter) * s;
        }
    }

    // NTSC: the raster shivers a little under the carrier.
    if (mode > 1.5) {
        uv.x += sin(time * 2.0 + uv.y * 34.0) * 0.0007 * s;
    }

    // Chroma separation: the colour channels arrive at different times.
    float2 p = float2(uv.x * w, uv.y * h);
    float sep = bleed * s * 7.0;
    float4 a = src.sample(src.transform(p - float2(sep, 0.0)));
    float4 b = src.sample(src.transform(p));
    float4 c = src.sample(src.transform(p + float2(sep, 0.0)));
    float4 col = float4(a.r, b.g, c.b, b.a);

    // Scanlines, spaced by the raster rather than the pixel grid.
    if (scanline > 0.001) {
        float pitch = max(2.0, h / 480.0);
        float lines = 0.5 + 0.5 * cos(dc.y * 6.2831853 / pitch);
        col.rgb *= 1.0 - scanline * s * 0.5 * lines;
    }

    // Phosphor triads.
    if (maskAmount > 0.001) {
        float cell = fmod(dc.x, 3.0);
        float3 mask = float3(0.75);
        if (cell < 1.0) { mask = float3(1.0, 0.72, 0.72); }
        else if (cell < 2.0) { mask = float3(0.72, 1.0, 0.72); }
        else { mask = float3(0.72, 0.72, 1.0); }
        col.rgb *= mix(float3(1.0), mask, maskAmount * s);
    }

    // Grain, plus the occasional speck of snow.
    if (noiseAmount > 0.001) {
        float n = hash21(uv * float2(w, h) + float2(time * 91.7, time * 47.3));
        col.rgb += (n - 0.5) * noiseAmount * s * 0.45;
        float speck = step(0.9975 - noiseAmount * s * 0.02, n);
        col.rgb = mix(col.rgb, float3(n), speck * 0.75);
    }

    return col;
}

}
}
