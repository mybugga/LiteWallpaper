// Magic book: an old leather book floating open in the dark, golden light pouring out of it. It bobs
// and tilts gently as it floats, the light between its pages pulses, golden sparks stream up out of
// the pages in a rising plume, the golden haze above flows upward, and the loose page tips lift and
// flutter in the updraft.
// texture: assets/book.jpg
// texture1: assets/book_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kCentre = float2(1240.0, 480.0); // middle of the book
static const float2 kGlow = float2(1238.0, 430.0);   // the light between the pages

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = the book (floats), g = golden haze above it (flows up), b = loose page tips (flutter).
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).g; }
#include "fx.hlsli"

float2 floatOffset(float t) { return float2(3.0 * sin(t * 0.37), 7.0 * sin(t * 0.55)); }
float floatAngle(float t) { return radians(0.5 * sin(t * 0.43 + 1.0)); }

// Golden sparks pouring up out of the pages: each starts in the light between the pages (where the
// book was when it left), rises and spreads up and to the right like the plume, twinkling and
// fading. A fixed set, each reborn somewhere new once it fades.
float3 sparks(float2 q, float t) {
    float3 col = 0;
    [loop] for (int i = 0; i < 140; i++) {
        float h0 = hash21(float2(i, 2.3));
        float period = 2.2 + 2.6 * hash21(float2(i, 4.1));
        float cyc = t / period + h0;
        float age = frac(cyc) * period;
        float2 id = float2(i, floor(cyc));
        float life = period * 0.95;
        if (age >= life) continue;
        // Born along the gap between the pages, most near the spine.
        float u = hash21(id + 0.3) - 0.5;
        float2 born = kGlow + float2(u * 230.0, -abs(u) * 150.0 - 10.0 * hash21(id + 0.9));
        float2 start = kCentre + rot(born - kCentre, floatAngle(t - age)) + floatOffset(t - age);
        float2 v = float2(-10.0 + 60.0 * hash21(id + 1.7) + u * 60.0, -(70.0 + 90.0 * hash21(id + 2.9)));
        float2 pos = start + v * age + float2(10.0 * sin(age * 1.8 + h0 * 30.0), 6.0 * age * age);
        float2 rel = q - pos;
        if (abs(rel.x) > 20.0 || abs(rel.y) > 20.0) continue;
        float k = age / life;
        float sz = (1.0 + 1.9 * pow(hash21(id + 5.5), 2.0)) * (1.0 - 0.4 * k);
        float d = length(rel);
        float tw = 0.6 + 0.4 * sin(t * (6.0 + 6.0 * h0) + h0 * 40.0);
        float fade = smoothstep(0.0, 0.08, k) * pow(1.0 - k, 1.3);
        float3 c = lerp(float3(1.0, 0.92, 0.65), float3(1.0, 0.62, 0.22), k);
        col += c * (exp(-d * d / (2.0 * sz * sz)) * 1.5 + exp(-d / (sz * 4.0)) * 0.35) * fade * tw;
    }
    return col;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The book floats: it bobs and tilts a little.
    float w = parts(q).r;
    float2 qs = lerp(q, kCentre + rot(q - kCentre - floatOffset(t), -floatAngle(t)), w);

    // The loose page tips lift and flutter in the updraft.
    float tip = parts(qs).b;
    if (tip > 0.001) {
        float2 n = float2(noise(qs / 14.0 + float2(t * 1.7, 0.0)), noise(qs / 14.0 + float2(3.0, -t * 1.5))) - 0.5;
        qs += (n * 5.0 + float2(0.0, 2.5 * sin(t * 2.2 + qs.x / 30.0))) * tip;
    }

    // The golden haze above flows upward; the air near the book moves with the book.
    float hold = smoothstep(0.25, 0.75, w);
    float3 col = picture(qs);
    if (hold < 1.0) col = lerp(streamSmoke(q, t, float2(9.0, -20.0)), col, hold);

    // The light between the pages pulses, and the pages it falls on brighten with it.
    float pulse = 0.5 + 0.5 * sin(t * 1.4) + 0.15 * (noise(float2(t * 3.0, 2.0)) - 0.5);
    float2 glowAt = kCentre + rot(kGlow - kCentre, floatAngle(t)) + floatOffset(t);
    float rg = length((q - glowAt) * float2(1.0, 1.3));
    float lit = smoothstep(0.35, 0.85, dot(col, float3(0.3, 0.5, 0.2)));
    col += col * lit * exp(-rg / 160.0) * (0.15 + 0.3 * pulse);
    col += float3(1.0, 0.75, 0.35) * (exp(-rg / 22.0) * 0.35 + exp(-rg / 110.0) * 0.08) * (0.5 + pulse);

    // More golden haze swirling up out of the book.
    float plume = smoothstep(470.0, 300.0, q.y) * smoothstep(1040.0, 1160.0, q.x) * smoothstep(1560.0, 1440.0, q.x) * (1.0 - hold);
    if (plume > 0.01) {
        float d = smokeDensity(q, t, float2(12.0, -30.0), 90.0) * plume;
        col += float3(0.5, 0.34, 0.13) * d * 0.3 * (0.6 + 0.4 * pulse);
    }

    if (q.x > 900.0 && q.y < 520.0) col += sparks(q, t);
    return float4(col, 1.0);
}
