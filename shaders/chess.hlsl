// Chess king: a black marble king split by gold-filled cracks. Molten light flows up through the
// cracks and pulses, waves of light run out along the cracks in the floor, sparks drift up off the
// cracks, the broken shards float around it, bobbing and turning and catching the light, and
// the smoke at its feet drifts.
// texture: assets/chess.jpg
// texture1: assets/chess_shards.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kBase = float2(1205.0, 765.0);  // the king stands here
static const float kFloor = 760.0;                  // the floor starts below this
static const float kAtlasScale = 2560.0 / 1672.0;   // shard atlas pixels per picture pixel
static const float kCell = 120.0;
static const float2 kShards[6] = { float2(989.4, 449.1), float2(1412.6, 170.1), float2(1440.9, 572.9),
                                   float2(1367.3, 119.0), float2(1368.9, 464.8), float2(906.5, 730.8) };

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// How gold a colour is: the glowing cracks and the light on the edges.
float goldness(float3 c) { return saturate(((c.r - c.b) / max(c.r, 0.02) - 0.38) * 2.5) * smoothstep(0.16, 0.5, c.r); }

// The faint smoke: low on the right and at the far left of the king's base.
float smokeMask(float2 q) {
    float right = smoothstep(1430.0, 1480.0, q.x) * smoothstep(420.0, 500.0, q.y);
    float left = smoothstep(1010.0, 960.0, q.x) * smoothstep(630.0, 690.0, q.y);
    return saturate(right + left) * smoothstep(790.0, 750.0, q.y) * (1.0 - goldness(picture(q)));
}
#include "fx.hlsli"

// Sparks drifting up off the cracks. Each starts on (or just beside) a glowing crack, rises with a
// gentle sway, and fades. Kept in a grid by where they start; each one's travel fits the cells
// checked, and sparks that can't reach this pixel are skipped before any texture is read.
float3 crackSparks(float2 q, float t, float cell, float chance, float size, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int dx = -1; dx <= 1; dx++)
    [unroll] for (int dy = 0; dy <= 2; dy++) {
        float2 id = base + float2(dx, dy);
        if (hash21(id + seed) > chance) continue;
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float period = 2.2 + 1.6 * hash21(id + seed + 3.0);
        float life = period * 0.9;
        float rise = min(18.0 + 14.0 * hash21(id + seed + 5.0), 1.9 * cell / life);
        if (abs(q.x - spawn.x) > 16.0 || q.y > spawn.y + 12.0 || q.y < spawn.y - rise * life - 12.0) continue;
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        if (age > life || spawn.y > kFloor) continue;
        float g = goldness(picture(spawn));
        [unroll] for (int k = 0; k < 4; k++) {
            float a = k * 1.5708 + 0.4;
            g = max(g, goldness(picture(spawn + float2(cos(a), sin(a)) * 6.0)));
        }
        if (g < 0.4) continue;
        float2 pos = spawn + float2(5.0 * sin(age * 2.2 + seed + id.x) * age / life, -rise * age);
        float d = length(q - pos);
        float s = size * (0.7 + 0.8 * pow(hash21(id + seed + 6.0), 2.0));
        float fade = smoothstep(0.0, 0.2, age) * pow(1.0 - age / life, 1.3);
        float flicker = 0.75 + 0.25 * sin(t * 11.0 + hash21(id + seed + 7.0) * 40.0);
        col += float3(1.0, 0.68, 0.28) * (exp(-d * d / (2.0 * s * s)) * 1.5 + exp(-d / (s * 4.0)) * 0.4) * fade * flicker
               * smoothstep(14.0, 8.0, d);
    }
    return col;
}

// The floating shards: each bobs, sways and turns a little, and its gold edge flares as it turns.
float3 drawShards(float2 q, float t, float3 col) {
    [unroll] for (int i = 0; i < 6; i++) {
        float ph = i * 1.7 + 0.4;
        float2 off = float2(3.5 * sin(t * 0.37 + ph * 1.3), 7.0 * sin(t * (0.55 + 0.07 * i) + ph));
        float ang = 0.24 * sin(t * (0.42 + 0.05 * i) + ph * 2.1);
        float sc = 1.0 + 0.035 * sin(t * 0.5 + ph);
        float2 lp = rot(q - kShards[i] - off, -ang) / sc * kAtlasScale;
        if (abs(lp.x) > kCell * 0.5 || abs(lp.y) > kCell * 0.5) continue;
        float2 uv = (lp + float2(kCell * (i + 0.5), kCell * 0.5)) / float2(kCell * 6.0, kCell);
        float4 s = iChannel1.SampleLevel(iSampler, uv, 0);
        float flare = pow(saturate(sin(t * (0.42 + 0.05 * i) + ph * 2.1)), 8.0);
        s.rgb *= 1.0 + 1.6 * flare * goldness(s.rgb / max(s.a, 0.01));
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

    // The smoke drifts up and away.
    float3 col = streamSmoke(q, t, float2(q.x > 1300.0 ? 8.0 : -8.0, -10.0));
    float gold = goldness(col);

    // Molten light flows up through the cracks and the whole king's glow breathes.
    float breathe = 0.5 + 0.5 * sin(t * 1.1);
    if (q.y < kFloor) {
        float flow = noise(float2(q.x / 22.0, q.y / 30.0 + t * 1.3)) * 0.65 + noise(float2(q.x / 60.0, q.y / 80.0 + t * 0.6)) * 0.35;
        col += col * gold * (1.1 * (flow - 0.4) + 0.3 * breathe);
    } else {
        // Waves of light run out from the king along the cracks in the floor (and its reflection).
        float dist = length((q - kBase) * float2(1.0, 3.2));
        float wave = pow(0.5 + 0.5 * sin(dist / 22.0 - t * 2.4), 5.0);
        col += col * gold * (1.6 * wave + 0.2 * breathe);
    }
    // Their glow spills round them.
    if (q.x > 980.0 && q.x < 1440.0 && q.y > 20.0 && q.y < 800.0) {
        float halo = 0.0;
        [unroll] for (int i = 0; i < 8; i++) {
            float a = i * 0.785;
            halo += goldness(picture(q + float2(cos(a), sin(a)) * 7.0));
        }
        col += float3(1.0, 0.6, 0.18) * halo / 8.0 * (0.06 + 0.1 * breathe);
    }

    // Own smoke rolling low along the floor, lit warm near the king.
    float low = smoothstep(640.0, 730.0, q.y) * smoothstep(800.0, 760.0, q.y);
    if (low > 0.01) {
        float d = smokeDensity(q, t, float2(-10.0, -3.0), 200.0) * low;
        float warm = exp(-length((q - kBase) * float2(1.0, 2.0)) / 260.0);
        col += lerp(float3(0.07, 0.065, 0.06), float3(0.22, 0.14, 0.05), warm) * d;
    }

    col = drawShards(q, t, col);
    if (q.x > 960.0 && q.x < 1460.0 && q.y < 790.0) {
        col += crackSparks(q, t, 32.0, 1.0, 1.7, 1.0);
        col += crackSparks(q, t, 44.0, 1.0, 2.4, 13.0) * 0.85;
        col += crackSparks(q, t, 26.0, 1.0, 1.2, 29.0);
    }
    return float4(col, 1.0);
}
