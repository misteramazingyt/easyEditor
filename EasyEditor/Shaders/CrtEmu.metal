#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// A port of crtemu.h's CRT fragment shader to Metal, for Core Image.
//
//   newpixie / crtemu.h — Copyright (c) 2016 Mattias Gustavsson
//   Dual-licensed MIT / public domain (Unlicense).
//   https://github.com/mattiasgustavsson/newpixie
//
// The structure is carried over rather than reinvented: barrel curve, RGB
// separation with a per-line wobble, ghosting sampled from a blurred copy of
// the frame (crtemu's "blurbuffer"), level curves, vignette, moving scanlines,
// shadow mask, filmic tone map, noise and flicker. The TV bezel texture is
// left out — we are dressing a video, not drawing a television.

// The phosphor bloom that runs *before* the tube. Ported from the outro
// renderer, where the halo's radii and gains were fitted against the reference
// artwork's measured falloff (mean-to-core ratio in rings 1-10, 10-25, 25-50,
// 50-90 and 90-150 px out from the ink) rather than eyeballed.
//
// The merge is the part that matters: a lit phosphor dot is what it is, and the
// halo is light scattered *around* it, so the glow has no business brightening
// the dot. Weighting it by how dark the picture already is adds it only in the
// surround — which is what puts a halo in the black around a clip instead of a
// flat wash over it.

static inline float crtRand(float2 co) {
    return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

static inline float2 crtCurve(float2 uv) {
    uv = (uv - 0.5) * 2.0;
    uv *= 1.1;
    uv.x *= 1.0 + pow((abs(uv.y) / 5.0), 2.0);
    uv.y *= 1.0 + pow((abs(uv.x) / 4.0), 2.0);
    uv = (uv / 2.0) + 0.5;
    uv = uv * 0.92 + 0.04;
    return uv;
}

static inline float3 crtFilmic(float3 linearColor) {
    float3 x = max(float3(0.0), linearColor - float3(0.004));
    return (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06);
}

extern "C" {
namespace coreimage {

// crtemu samples with the texture's y flipped and works in linear light;
// tc arrives in top-left-origin uv, and Core Image wants bottom-left pixels.
static inline float3 crtSample(sampler samp, float2 tc, float w, float h) {
    tc = tc * float2(1.025, 0.92) + float2(-0.0125, 0.04);
    float2 p = float2(tc.x * w, (1.0 - tc.y) * h);
    float3 s = pow(abs(samp.sample(samp.transform(p)).rgb), float3(2.2));
    return s * float3(1.25);
}

/// Keep only what is bright enough to bloom. A soft knee rather than a step, or
/// the glow's own edge shows up as a contour around the picture.
float4 phosphorThreshold(sample_t c, float threshold) {
    float l = max(max(c.r, c.g), c.b);
    float k = smoothstep(threshold, threshold + 0.25, l);
    return float4(c.rgb * k, c.a);
}

/// Put the blurred copies *behind* the picture rather than over it.
float4 phosphorMerge(sample_t base, sample_t tight, sample_t wide,
                     float tightGain, float wideGain) {
    float3 lit = clamp(base.rgb, 0.0, 1.0);
    float3 halo = tight.rgb * tightGain + wide.rgb * wideGain;
    float room = clamp(1.0 - max(max(lit.r, lit.g), lit.b), 0.0, 1.0);
    return float4(clamp(lit + halo * room, 0.0, 1.0), 1.0);
}

/// `blur` is a pre-blurred copy of `src` — crtemu's blurbuffer, which is what
/// the phosphor ghosting is drawn from.
float4 crtEmuPass(sampler src, sampler blur,
                  float w, float h, float time, float strength,
                  destination dest)
{
    float2 dc = dest.coord();
    float2 res = float2(max(w, 1.0), max(h, 1.0));
    float2 uv = float2(dc.x / res.x, 1.0 - dc.y / res.y);

    float2 curved_uv = mix(crtCurve(uv), uv, 0.4);
    float scale = 0.04;
    float2 scuv = curved_uv * (1.0 - scale) + scale / 2.0 + float2(0.003, -0.001);

    // Main colour, with the separation wobbling line by line.
    float3 col;
    float x = sin(0.1 * time + curved_uv.y * 13.0)
            * sin(0.23 * time + curved_uv.y * 19.0)
            * sin(0.3 + 0.11 * time + curved_uv.y * 23.0) * 0.0012;
    float o = sin(dc.y * 1.5) / res.x;
    x += o * 0.25;
    col.r = crtSample(src, float2(x + scuv.x + 0.0009, scuv.y + 0.0009), res.x, res.y).x + 0.02;
    col.g = crtSample(src, float2(x + scuv.x + 0.0000, scuv.y - 0.0011), res.x, res.y).y + 0.02;
    col.b = crtSample(src, float2(x + scuv.x - 0.0015, scuv.y + 0.0000), res.x, res.y).z + 0.02;

    float i = clamp(col.r * 0.299 + col.g * 0.587 + col.b * 0.114, 0.0, 1.0);
    i = pow(1.0 - pow(i, 2.0), 1.0);
    i = (1.0 - i) * 0.85 + 0.15;

    // Ghosting, off the blurred copy.
    float ghs = 0.15;
    float3 r = crtSample(blur,
        float2(x - 0.014, -0.027) * 0.85
        + 0.007 * float2(0.35 * sin(1.0 / 7.0 + 15.0 * curved_uv.y + 0.9 * time),
                         0.35 * sin(2.0 / 7.0 + 10.0 * curved_uv.y + 1.37 * time))
        + float2(scuv.x + 0.001, scuv.y + 0.001), res.x, res.y) * float3(0.5, 0.25, 0.25);
    float3 g = crtSample(blur,
        float2(x - 0.019, -0.020) * 0.85
        + 0.007 * float2(0.35 * cos(1.0 / 9.0 + 15.0 * curved_uv.y + 0.5 * time),
                         0.35 * sin(2.0 / 9.0 + 10.0 * curved_uv.y + 1.50 * time))
        + float2(scuv.x + 0.000, scuv.y - 0.002), res.x, res.y) * float3(0.25, 0.5, 0.25);
    float3 b = crtSample(blur,
        float2(x - 0.017, -0.003) * 0.85
        + 0.007 * float2(0.35 * sin(2.0 / 3.0 + 15.0 * curved_uv.y + 0.7 * time),
                         0.35 * cos(2.0 / 3.0 + 10.0 * curved_uv.y + 1.63 * time))
        + float2(scuv.x - 0.002, scuv.y + 0.000), res.x, res.y) * float3(0.25, 0.25, 0.5);

    col += float3(ghs * (1.0 - 0.299)) * pow(clamp(3.0 * r, 0.0, 1.0), float3(2.0)) * float3(i);
    col += float3(ghs * (1.0 - 0.587)) * pow(clamp(3.0 * g, 0.0, 1.0), float3(2.0)) * float3(i);
    col += float3(ghs * (1.0 - 0.114)) * pow(clamp(3.0 * b, 0.0, 1.0), float3(2.0)) * float3(i);

    // Level adjustment.
    col *= float3(0.95, 1.05, 0.95);
    col = clamp(col * 1.3 + 0.75 * col * col + 1.25 * col * col * col * col * col,
                float3(0.0), float3(10.0));

    // Vignette.
    float vig = (0.1 + 16.0 * curved_uv.x * curved_uv.y
                 * (1.0 - curved_uv.x) * (1.0 - curved_uv.y));
    vig = 1.3 * pow(vig, 0.5);
    col *= vig;

    // Scanlines, drifting with time.
    float scans = clamp(0.35 + 0.18 * sin(6.0 * time + curved_uv.y * res.y * 1.5), 0.0, 1.0);
    col *= float3(pow(scans, 0.9));

    // Shadow mask.
    col *= 1.0 - 0.23 * clamp(fmod(dc.x, 3.0) / 2.0, 0.0, 1.0);

    col = crtFilmic(col);

    // Noise.
    float2 seed = curved_uv * res;
    col -= 0.015 * pow(float3(crtRand(seed + time),
                              crtRand(seed + time * 2.0),
                              crtRand(seed + time * 3.0)), float3(1.5));

    // Flicker.
    col *= (1.0 - 0.004 * (sin(50.0 * time + curved_uv.y * 2.0) * 0.5 + 0.5));

    // Nothing outside the glass.
    if (curved_uv.x < 0.0 || curved_uv.x > 1.0) { col *= 0.0; }
    if (curved_uv.y < 0.0 || curved_uv.y > 1.0) { col *= 0.0; }

    // Dial the whole tube in against the untouched frame.
    float4 original = src.sample(src.transform(dc));
    float k = clamp(strength, 0.0, 1.0);
    return float4(mix(original.rgb, col, k), 1.0);
}

}
}
