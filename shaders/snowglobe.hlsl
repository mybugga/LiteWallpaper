// Snow globe: a mountain cabin inside a glass globe. Snow swirls round inside the glass as if the
// globe had just been shaken, smoke curls up from the chimney, firelight flickers in the windows,
// mist drifts round the mountain, and a glint slides over the glass.
// texture: assets/snowglobe.jpg
// texture1: assets/snowglobe_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kCentre = float2(1250.0, 390.0);  // the globe
static const float kRadius = 345.0;
static const float2 kChimney = float2(1362.0, 378.0);
static const float2 kCabin = float2(1325.0, 470.0);

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = warm window light, g = mist, b = inside the globe.
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }

// The chimney's painted smoke: bright wisps just above the chimney.
float chimneySmoke(float2 q) {
    float region = smoothstep(1318.0, 1332.0, q.x) * smoothstep(1402.0, 1388.0, q.x) * smoothstep(270.0, 290.0, q.y) * smoothstep(382.0, 370.0, q.y);
    return region * smoothstep(0.3, 0.55, dot(picture(q), float3(0.3, 0.5, 0.2)));
}
float smokeMask(float2 q) { return max(parts(q).g, chimneySmoke(q)); }
#include "fx.hlsli"

// One depth of swirling snow: flakes fall slowly while the whole flurry circles round the globe.
// Neighbouring cells are checked too, so a flake's glow is never cut off.
float snowLayer(float2 q, float t, float cell, float fall, float swirl, float size, float density, float seed) {
    float2 w = rot(q - kCentre, -swirl * t);  // turn with the flurry
    float2 g = (w - float2(0.0, fall * t)) / cell;
    float2 base = floor(g);
    float v = 0.0;
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 id = base + float2(i, j);
        if (hash21(id + seed) > density) continue;
        float2 c = id + 0.5 + (float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0)) - 0.5) * 0.6;
        c.x += 0.3 * sin(t * (0.8 + hash21(id + seed + 3.0)) + hash21(id + seed + 4.0) * 6.28);  // flutter
        float d = length((g - c) * cell);
        float s = size * (0.6 + 0.8 * hash21(id + seed + 5.0));
        float tw = 0.7 + 0.3 * sin(t * (2.0 + 3.0 * hash21(id + seed + 6.0)) + hash21(id + seed + 7.0) * 30.0);  // turning, glinting
        v += (exp(-d * d / (2.0 * s * s)) + exp(-d / (s * 2.5)) * 0.12) * tw;
    }
    return v;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 fx = parts(q);
    float inside = fx.b;

    // The mist drifts round the mountain; the chimney's own smoke rises.
    float3 col = picture(q);
    if (smokeMask(q) > 0.001) col = streamSmoke(q, t, chimneySmoke(q) > 0.01 ? float2(-3.0, -14.0) : float2(9.0, -1.0));

    // Firelight flickers in the windows and on the snow in front.
    float flicker = 1.0 + 0.3 * (noise(float2(t * 4.0, 1.0)) - 0.5) + 0.14 * (noise(float2(t * 11.0, 5.0)) - 0.5);
    col += col * fx.r * (flicker - 1.0) * 1.6;

    // More mist drifting round the mountainside.
    float mistBand = smoothstep(255.0, 300.0, q.y) * smoothstep(380.0, 330.0, q.y) * inside;
    if (mistBand > 0.01) {
        float d = smokeDensity(q, t, float2(10.0, 0.0), 120.0) * mistBand;
        col += float3(0.5, 0.52, 0.56) * d * 0.45;
    }

    // Smoke curling up from the chimney, drifting left as it rises and thinning out.
    float h = kChimney.y - q.y;
    if (h > -4.0 && h < 260.0) {
        float cx = kChimney.x - 0.18 * h - 0.0007 * h * h + 6.0 * sin(h / 30.0 - t * 1.1);
        float width = 5.0 + 0.22 * h;
        float plume = exp(-pow((q.x - cx) / width, 2.0)) * smoothstep(-4.0, 10.0, h) * exp(-h / 150.0);
        float puffs = fbm3(float2((q.x - cx) / 16.0, (q.y + t * 24.0) / 20.0));
        col += float3(0.8, 0.8, 0.83) * plume * smoothstep(0.3, 0.75, puffs) * 0.65 * inside;
    }

    // Snow swirling inside the glass, warm near the cabin's light.
    float snow = snowLayer(q, t, 18.0, 16.0, 0.05, 0.9, 0.55, 1.0) * 0.75
               + snowLayer(q, t, 28.0, 24.0, 0.06, 1.5, 0.5, 11.0)
               + snowLayer(q, t, 46.0, 34.0, 0.075, 2.7, 0.4, 23.0) * 0.85;
    float warm = exp(-length(q - kCabin) / 140.0) * flicker;
    col += lerp(float3(0.82, 0.88, 1.0), float3(1.0, 0.82, 0.55), saturate(warm)) * snow * inside * 0.9;

    // A glint slides over the top of the glass every ten seconds.
    float2 d = q - kCentre;
    float rr = length(d);
    float a = atan2(d.y, d.x);
    float a0 = lerp(-2.95, -0.25, frac(t / 10.0));
    float da = a - a0;
    float rim = exp(-pow((rr - (kRadius - 14.0)) / 9.0, 2.0)) * exp(-da * da / 0.012);
    col += float3(1.0, 0.98, 0.94) * rim * 0.55;

    // The brass rim of the base catches the light now and then.
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    col += float3(1.0, 0.9, 0.7) * twinkle(q, t, 4.0, 36.0) * smoothstep(0.55, 0.85, lum) * step(640.0, q.y) * step(q.y, 700.0) * 0.8;
    return float4(col, 1.0);
}
