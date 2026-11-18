// Molten rock: a burning rock floating in the dark, split by cracks of lava. The lava flows and
// pulses inside the cracks, embers burst out of them and fly off in every direction, smoke streams
// up off the rock with more rising from its top, the air shimmers with heat above it, and the
// rock itself drifts and turns very slightly as it floats.
// texture: assets/meteor.jpg
// texture1: assets/meteor_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kCentre = float2(1272.0, 475.0);  // middle of the rock

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = the rock with a dark margin (floats as one piece), g = smoke.
float2 regions(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rg; }
float smokeMask(float2 q) { return regions(q).g; }
#include "fx.hlsli"

// How much a colour is glowing lava.
float lava(float3 c) { return saturate(((c.r - c.b) / max(c.r, 0.02) - 0.6) * 3.0) * smoothstep(0.3, 0.75, c.r); }

// Embers bursting out of the cracks: each starts on glowing lava and flies out from the rock (and
// a little upward), trailing a short streak, flickering and fading. Kept in a grid by where they
// start; each one's flight fits the cells checked, and only embers whose path passes this pixel
// read the texture.
float3 lavaEmbers(float2 q, float t, float cell, float size, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    // Real loops: unrolled, three calls of this grid took the compiler 40 s.
    [loop] for (int dy = -2; dy <= 2; dy++)
    [loop] for (int dx = -2; dx <= 2; dx++) {
        float2 id = base + float2(dx, dy);
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float period = 1.6 + 1.6 * hash21(id + seed + 3.0);
        float life = period * 0.85;
        float2 away = normalize(spawn - kCentre + float2(0.0, -60.0) + (float2(hash21(id + seed + 8.0), hash21(id + seed + 9.0)) - 0.5) * 160.0);
        float speed = min(45.0 + 70.0 * hash21(id + seed + 5.0), 1.8 * cell / life);
        float2 v = away * speed;
        // Skip embers whose flight can't pass this pixel (before reading the picture).
        float2 rel = q - spawn;
        float tAlong = clamp(dot(rel, v) / dot(v, v), 0.0, life);
        if (length(rel - v * tAlong) > 22.0) continue;
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        if (age > life) continue;
        float g = lava(picture(spawn));
        [unroll] for (int k = 0; k < 6; k++) {
            float a = k * 1.0472 + 0.4;
            g = max(g, lava(picture(spawn + float2(cos(a), sin(a)) * 11.0)));
        }
        if (g < 0.35) continue;
        float2 pos = spawn + v * age + float2(0.0, -6.0 * age * age);
        // A short streak behind it, along its flight.
        float2 back = -normalize(v) * min(speed * 0.09, 9.0);
        float2 pa = q - pos;
        float d = length(pa - back * saturate(dot(pa, back) / dot(back, back)));
        float s = size * (0.6 + 0.9 * pow(hash21(id + seed + 6.0), 2.0));
        float fade = smoothstep(0.0, 0.12, age) * pow(1.0 - age / life, 1.4);
        float flicker = 0.7 + 0.3 * sin(t * 13.0 + hash21(id + seed + 7.0) * 40.0);
        float3 hot = lerp(float3(1.0, 0.35, 0.05), float3(1.0, 0.8, 0.35), pow(1.0 - age / life, 2.0));  // cools as it flies
        col += hot * (exp(-d * d / (2.0 * s * s)) * 1.6 + exp(-d / (s * 4.0)) * 0.4) * fade * flicker * smoothstep(20.0, 12.0, d);
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

    float2 reg = regions(q);

    // Heat haze rising above the rock.
    float hazeArea = smoothstep(360.0, 220.0, q.y) * smoothstep(1020.0, 1120.0, q.x) * smoothstep(1660.0, 1560.0, q.x);
    float2 haze = (float2(noise(q / 16.0 + float2(0.0, t * 2.2)), noise(q / 16.0 + float2(7.0, t * 2.0))) - 0.5) * 3.0 * hazeArea;

    // The rock drifts and turns a touch as it floats.
    float2 drift = float2(2.5 * sin(t * 0.31), 5.0 * sin(t * 0.47));
    float turn = 0.012 * sin(t * 0.29);
    float2 qr = lerp(q, kCentre + rot(q - kCentre - drift, -turn), reg.r) + haze;

    float3 col = reg.g > 0.001 ? streamSmoke(q + haze, t, float2(-3.0, -17.0)) : picture(qr);
    col += col * reg.g * smokeWisps(q, t) * 0.4;

    // The lava flows inside the cracks and pulses; white-hot where it's thickest.
    float l = lava(col);
    float breath = 0.5 + 0.5 * sin(t * 1.2) + 0.15 * (noise(float2(t * 3.0, 1.0)) - 0.5);
    float flow = fbm3(qr / 40.0 + float2(t * 0.05, -t * 0.16));
    col += col * l * (1.1 * (flow - 0.4) + 0.35 * breath);
    col += float3(1.0, 0.75, 0.35) * l * smoothstep(0.62, 0.85, flow) * 0.35;
    // Its glow spills over the rock round the cracks.
    if (reg.r > 0.5) {
        float halo = 0.0;
        [unroll] for (int i = 0; i < 8; i++) {
            float a = i * 0.785;
            halo += lava(picture(qr + float2(cos(a), sin(a)) * 9.0));
        }
        col += float3(1.0, 0.35, 0.06) * halo / 8.0 * (0.05 + 0.08 * breath);
    }

    // Smoke rising off the top of the rock, warm where the lava lights it from below.
    // (above the rock's top edge: from the top of the screen down to just over the rock)
    float above = smoothstep(0.0, 90.0, q.y) * smoothstep(330.0, 200.0, q.y) * smoothstep(1080.0, 1200.0, q.x) * smoothstep(1650.0, 1540.0, q.x);
    float left = smoothstep(860.0, 960.0, q.x) * smoothstep(1110.0, 1000.0, q.x) * smoothstep(130.0, 260.0, q.y) * smoothstep(520.0, 400.0, q.y) * 0.5;
    float rise = max(above, left) * (1.0 - reg.r);
    if (rise > 0.01) {
        float d = smokeDensity(q, t, float2(-4.0, -26.0), 110.0) * rise;
        float warm = smoothstep(150.0, 320.0, q.y);
        col += lerp(float3(0.11, 0.105, 0.1), float3(0.17, 0.12, 0.09), warm) * d * 0.8;
    }

    // Embers bursting out of the cracks.
    if (q.x > 760.0 && q.y < 1000.0) {
        col += lavaEmbers(q, t, 60.0, 2.2, 1.0);
        col += lavaEmbers(q, t, 80.0, 3.0, 23.0) * 0.9;
        col += lavaEmbers(q, t, 50.0, 1.6, 41.0);
    }
    return float4(col, 1.0);
}
