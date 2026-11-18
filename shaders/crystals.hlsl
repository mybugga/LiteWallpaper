// Crystals: a cluster of glowing green and purple crystals on a dark rock. Light rises through the
// crystals in slow waves and their inner fire shifts, a sheen sweeps across their faces, sharp
// glints flash on the facets, the gold veins in the rock shimmer, the broken-off crystal bits float
// and turn in the air, and glowing motes drift up off the crystals.
// texture: assets/crystals.jpg
// texture1: assets/crystal_shards.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float kAtlasScale = 2560.0 / 1672.0;  // shard atlas pixels per picture pixel
static const float kCell = 96.0;
static const float2 kShards[9] = { float2(1602.6, 111.0), float2(1546.5, 159.4), float2(1471.9, 171.5),
                                   float2(1165.6, 225.2), float2(1189.0, 270.7), float2(1122.2, 187.2),
                                   float2(1613.4, 366.2), float2(982.8, 489.9), float2(857.1, 672.9) };

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// How much a colour is glowing crystal; and whether it's the green (1) or the purple (0) kind.
float crystalGlow(float3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float sat = (mx - min(c.r, min(c.g, c.b))) / max(mx, 0.02);
    return smoothstep(0.3, 0.6, sat) * smoothstep(0.12, 0.5, mx) * step(c.g + c.b, c.r * 3.5);
}
float greenness(float3 c) { return saturate((c.g - max(c.r, c.b)) * 6.0); }

// Sharp four-pointed glints that flash on bright facets: one may sit in each cell, and it only
// lights where the crystal under it is bright. Neighbouring cells are checked so rays aren't cut.
float3 glints(float2 q, float t, float cell, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 id = base + float2(i, j);
        float2 at = (id + 0.2 + 0.6 * float2(hash21(id + seed), hash21(id + seed + 1.0))) * cell;
        float flash = pow(saturate(sin(t * (0.5 + 0.6 * hash21(id + seed + 2.0)) + hash21(id + seed + 3.0) * 30.0)), 40.0);
        if (flash < 0.01) continue;
        float3 c = picture(at);
        float bright = smoothstep(0.5, 0.8, max(c.r, max(c.g, c.b)));
        if (bright <= 0.0) continue;
        float2 d = q - at;
        float r = length(d);
        float star = exp(-r / 1.6) + (exp(-abs(d.y) / 0.7) * exp(-abs(d.x) / 9.0) + exp(-abs(d.x) / 0.7) * exp(-abs(d.y) / 9.0)) * 0.7;
        col += lerp(float3(1.0, 1.0, 1.0), c / max(max(c.r, max(c.g, c.b)), 0.05), 0.35) * star * flash * bright;
    }
    return col;
}

// Motes of light drifting up off the crystals, in the colour of the crystal they left.
float3 risingMotes(float2 q, float t, float cell, float size, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int dy = 0; dy <= 2; dy++)
    [unroll] for (int dx = -1; dx <= 1; dx++) {
        float2 id = base + float2(dx, dy);
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float period = 3.0 + 2.5 * hash21(id + seed + 3.0);
        float life = period * 0.9;
        float rise = min(14.0 + 14.0 * hash21(id + seed + 5.0), 1.9 * cell / life);
        if (abs(q.x - spawn.x) > 18.0 || q.y > spawn.y + 10.0 || q.y < spawn.y - rise * life - 10.0) continue;
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        if (age > life) continue;
        float3 c = picture(spawn);
        if (crystalGlow(c) < 0.5) continue;
        float2 pos = spawn + float2(7.0 * sin(age * 1.4 + seed + id.x) * age / life, -rise * age);
        float d = length(q - pos);
        float s = size * (0.6 + 0.8 * hash21(id + seed + 6.0));
        float fade = smoothstep(0.0, 0.25, age / life) * pow(1.0 - age / life, 1.2);
        float3 tint = lerp(c / max(max(c.r, max(c.g, c.b)), 0.05), 1.0, 0.25);
        col += tint * (exp(-d * d / (2.0 * s * s)) * 1.2 + exp(-d / (s * 3.5)) * 0.3) * fade * smoothstep(12.0, 7.0, d);
    }
    return col;
}

// The broken-off bits: each floats, bobs and slowly turns, flaring as a face catches the light.
float3 drawShards(float2 q, float t, float3 col) {
    [unroll] for (int i = 0; i < 9; i++) {
        float ph = i * 1.37 + 0.5;
        float2 off = float2(5.0 * sin(t * 0.31 + ph * 1.3) + 3.0 * sin(t * 0.17 + ph), 9.0 * sin(t * (0.42 + 0.05 * i) + ph));
        float ang = 0.45 * sin(t * (0.25 + 0.04 * i) + ph * 2.1);
        float sc = 1.0 + 0.05 * sin(t * 0.37 + ph);  // turning in depth
        float2 lp = rot(q - kShards[i] - off, -ang) / sc * kAtlasScale;
        if (abs(lp.x) > kCell * 0.5 || abs(lp.y) > kCell * 0.5) continue;
        float2 uv = (lp + float2(kCell * (i + 0.5), kCell * 0.5)) / float2(kCell * 9.0, kCell);
        float4 s = iChannel1.SampleLevel(iSampler, uv, 0);
        float flare = pow(saturate(sin(t * (0.25 + 0.04 * i) + ph * 2.1 + 0.8)), 10.0);
        s.rgb *= 1.0 + 1.8 * flare;
        col = col * (1.0 - s.a) + s.rgb;
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

    float3 col = picture(q);
    float glow = crystalGlow(col);
    float green = greenness(col);

    // Light rises through the crystals in slow waves (the green and purple ones out of step), and
    // the fire inside them shifts.
    float phase = green * 2.4;
    float rise = pow(0.5 + 0.5 * sin(q.y / 36.0 + t * 2.1 + phase + 2.0 * noise(q / 160.0)), 3.0);
    float inner = fbm3(float2(q.x / 28.0, q.y / 42.0 + t * 0.45));
    float breathe = 0.5 + 0.5 * sin(t * 0.8 + phase);
    col += col * glow * (0.75 * (rise - 0.2) + 0.6 * (inner - 0.45) + 0.2 * breathe);

    // A sheen sweeps across the crystal faces every nine seconds.
    float s = dot(q, normalize(float2(1.0, -0.65)));
    float sweep = lerp(500.0, 1700.0, frac(t / 9.0));
    float sheen = exp(-pow((s - sweep) / 40.0, 2.0));
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    col += (col * 0.9 + 0.04) * sheen * smoothstep(0.15, 0.5, lum) * (0.4 + 0.6 * glow);

    // The gold veins in the rock shimmer.
    float gold = saturate((col.r - col.b) * 4.0) * saturate((col.g - col.b) * 4.0) * smoothstep(0.15, 0.45, lum) * (1.0 - glow);
    col += col * gold * 0.8 * pow(0.5 + 0.5 * sin(q.x / 22.0 - q.y / 35.0 + t * 1.6), 4.0);

    col = drawShards(q, t, col);
    if (q.x > 780.0) {
        col += glints(q, t, 26.0, 1.0);
        col += risingMotes(q, t, 40.0, 1.5, 3.0) + risingMotes(q, t, 56.0, 2.2, 17.0) * 0.8;
    }
    return float4(col, 1.0);
}
