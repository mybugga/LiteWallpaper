// Waterfall cube: a tiny waterfall in a glass cube. The water pours down and foams where it lands,
// spray leaps up from the splash, rings ripple out across the pool, light shimmers on the bottom,
// mist drifts and rises, the leaves and ferns sway, and the glow on the table below ripples.
// texture: assets/waterfall.jpg
// texture1: assets/waterfall_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kImpact = float2(1345.0, 578.0);  // where the falls hit the pool
static const float kPoolTop = 572.0;                  // the pool's surface, from here...
static const float kPoolBottom = 660.0;               // ...to here (its front edge)
static const float2 kTree = float2(1330.0, 190.0);    // the tree's trunk leaves the rock here

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = falling water, g = mist, b = leaves and ferns.
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).g; }
#include "fx.hlsli"

// The falling water pours down: two copies slide down the falls, each fading out as the other
// fades in (a flow map), faster lower down as the water speeds up. Each pixel's cycle starts at a
// different moment, so there's no overall pulse; copies are kept within the falls (above its lip
// they repeat the water coming over it).
float3 pour(float2 q, float t, float m) {
    float3 here = picture(q);
    const float period = 0.32;
    float speed = 150.0 + 0.5 * max(q.y - 230.0, 0.0);
    float offset = noise(q / float2(45.0, 140.0));
    float ph1 = frac(t / period + offset), ph2 = frac(t / period + offset + 0.5);
    float w1 = 1.0 - abs(2.0 * ph1 - 1.0);
    float2 s1 = q - float2(0.0, speed * period * (ph1 - 0.5)), s2 = q - float2(0.0, speed * period * (ph2 - 0.5));
    s1.y = clamp(s1.y, 238.0, 566.0);
    s2.y = clamp(s2.y, 238.0, 566.0);
    float3 flowed = picture(s1) * w1 + picture(s2) * (1.0 - w1);
    return lerp(here, flowed, m * smoothstep(226.0, 252.0, q.y));
}

// Spray leaping up from the splash and falling back.
float3 spray(float2 q, float t, float cell, float size, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int dy = 0; dy <= 2; dy++)
    [unroll] for (int dx = -1; dx <= 1; dx++) {
        float2 id = base + float2(dx, dy);
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float2 rel0 = spawn - kImpact;
        if (abs(rel0.x) > 75.0 || abs(rel0.y) > 14.0) continue;  // only from the splash
        float period = 0.9 + 0.8 * hash21(id + seed + 3.0);
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        float2 v = float2((hash21(id + seed + 5.0) - 0.5) * 70.0 + rel0.x * 0.5, -(70.0 + 70.0 * hash21(id + seed + 6.0)));
        float2 pos = spawn + v * age + float2(0.0, 0.5 * 260.0 * age * age);  // gravity
        if (pos.y > spawn.y + 4.0) continue;
        float d = length(q - pos);
        float s = size * (0.6 + 0.8 * hash21(id + seed + 7.0));
        float fade = smoothstep(0.0, 0.08, age) * (1.0 - age / period);
        col += float3(0.75, 1.0, 1.0) * exp(-d * d / (2.0 * s * s)) * fade * smoothstep(cell * 0.9, cell * 0.6, d);
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

    float3 fx = parts(q);
    float2 qs = q;

    // Leaves and ferns sway in the moving air.
    if (fx.b > 0.001) {
        float sway = 2.2 * sin(t * 0.9 + q.x / 120.0) * saturate(length(q - kTree) / 220.0);
        qs += (float2(noise(q / 22.0 + t * 0.9), noise(q / 22.0 + 4.0 - t * 0.8)) - 0.5) * 3.0 * fx.b + float2(sway, sway * 0.4) * fx.b;
    }

    // Rings ripple out across the pool from where the water lands (flattened by perspective).
    float pool = smoothstep(kPoolTop - 4.0, kPoolTop + 8.0, q.y) * smoothstep(kPoolBottom + 4.0, kPoolBottom - 8.0, q.y) *
                 smoothstep(940.0, 970.0, q.x) * smoothstep(1600.0, 1570.0, q.x);
    float rings = 0.0;
    if (pool > 0.0) {
        float rd = length((q - kImpact) * float2(1.0, 3.6));
        float wave = sin(rd / 9.0 - t * 4.2) * exp(-rd / 260.0);
        float chop = noise(q / float2(30.0, 8.0) + float2(t * 0.6, 0.0)) - 0.5;
        qs += float2(0.0, (wave * 2.2 + chop * 2.0) * pool);
        rings = max(wave, 0.0) * pool;
    }

    // Below the cube, the glow on the table ripples.
    float table = smoothstep(752.0, 775.0, q.y);
    qs.x += sin(q.y / 6.0 - t * 2.5) * 1.6 * table * (0.6 + 0.4 * noise(q / 40.0 + t * 0.3));

    float3 col = fx.r > 0.001 ? pour(qs, t, fx.r) : picture(qs);
    if (fx.g > 0.001) col = lerp(col, streamSmoke(q, t, float2(5.0, -9.0)), fx.g);

    // White streaks racing down the falls, so the pour reads clearly.
    float streaks = smoothstep(0.62, 0.95, noise(float2(q.x / 2.6, (q.y - t * 260.0) / 28.0)));
    col += float3(0.7, 1.0, 1.0) * streaks * fx.r * 0.25;

    // Foam boiling where it lands.
    float foamArea = exp(-pow((q.y - kImpact.y + 8.0) / 22.0, 2.0)) * smoothstep(140.0, 60.0, abs(q.x - kImpact.x));
    float boil = noise(q / 7.0 + float2(0.0, -t * 3.0)) * 0.6 + noise(q / 15.0 + float2(t * 1.3, 0.0)) * 0.4;
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    col += col * foamArea * (boil - 0.45) * 0.9 * smoothstep(0.3, 0.6, lum);

    // The ripple crests catch the light; light shimmers on the bottom of the pool.
    col += float3(0.5, 1.0, 1.0) * rings * 0.07 * smoothstep(0.15, 0.4, lum);
    float bottom = smoothstep(650.0, 670.0, q.y) * smoothstep(752.0, 735.0, q.y) * smoothstep(945.0, 975.0, q.x) * smoothstep(1500.0, 1470.0, q.x);
    if (bottom > 0.0) {
        float2 cq = q / float2(26.0, 12.0);
        float caustic = pow(abs(sin(cq.x + 2.0 * noise(cq * 0.7 + t * 0.6)) * sin(cq.y * 1.3 + 2.0 * noise(cq * 0.6 - t * 0.5))), 0.35);
        col += float3(0.3, 1.0, 0.95) * pow(1.0 - caustic, 4.0) * bottom * 0.25 * smoothstep(0.05, 0.25, lum);
    }

    // Mist rising off the splash.
    float mistArea = smoothstep(420.0, 520.0, q.y) * smoothstep(600.0, 560.0, q.y) * smoothstep(170.0, 90.0, abs(q.x - kImpact.x));
    if (mistArea > 0.01) {
        float d = smokeDensity(q, t, float2(3.0, -22.0), 70.0) * mistArea;
        col += float3(0.55, 0.85, 0.85) * d * 0.35;
    }

    col += spray(q, t, 26.0, 1.4, 1.0);
    col += spray(q, t, 34.0, 2.0, 13.0) * 0.8;
    return float4(col, 1.0);
}
