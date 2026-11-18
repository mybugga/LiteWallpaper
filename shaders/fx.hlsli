// Shared effects for the picture wallpapers: drifting smoke, rising embers, rain, and rings on
// water. Positions are in picture pixels unless noted. Needs space.hlsli, and two functions the
// wallpaper defines before including this: picture(q), the picture's colour at picture pixel q,
// and smokeMask(q), how much of the picture at q is smoke (0-1); plus kImg, the picture's size.

// How far to bend the picture at q so its smoke billows and curls; slowly changing swirls on two
// scales. Multiply by how much smoke is there.
float2 smokeFlow(float2 q, float t) {
    float2 w = q / 160.0;
    float2 s1 = float2(fbm3(w + float2(0.0, -t * 0.08)), fbm3(w + 5.2 + float2(t * 0.05, -t * 0.06))) - 0.5;
    float2 s2 = float2(fbm3(w * 2.3 + s1 * 2.0 + t * 0.1), fbm3(w * 2.3 + 3.7 - t * 0.09)) - 0.5;
    return s1 * 22.0 + s2 * 9.0;
}

// Makes the picture's own smoke flow (a flow map): two copies of it slide along the flow
// (`drift`, picture pixels per second, plus swirls), each fading out as the other fades in, so it
// streams continuously without jumping. These are the two sampling offsets and the first copy's
// weight.
void smokeOffsets(float2 q, float t, float2 drift, out float2 o1, out float2 o2, out float w1) {
    const float period = 4.0;
    float2 swirl = smokeFlow(q, t) * 0.8;
    float2 travel = drift * period + swirl;
    float ph1 = frac(t / period), ph2 = frac(t / period + 0.5);
    o1 = -travel * (ph1 - 0.5);
    o2 = -travel * (ph2 - 0.5);
    w1 = 1.0 - abs(2.0 * ph1 - 1.0);  // ph1's copy is fully shown mid-cycle; ph2's then fades out
}

// Smoke outside the picture doesn't exist (sampling there would repeat its edge as streaks).
float smokeAt(float2 q) {
    float inside = step(0.0, q.x) * step(q.x, kImg.x) * step(0.0, q.y) * step(q.y, kImg.y);
    return smoothstep(0.55, 0.9, smokeMask(q)) * inside;
}

// The picture with its smoke streaming along `drift` (see smokeOffsets). Copies that would drag
// in something that isn't smoke (the robot, the car) are left out.
float3 streamSmoke(float2 q, float t, float2 drift) {
    float3 here = picture(q);
    float m = smokeMask(q);
    if (m <= 0.001) return here;
    float2 o1, o2;
    float w1;
    smokeOffsets(q, t, drift, o1, o2, w1);
    float a = w1 * smokeAt(q + o1), b = (1.0 - w1) * smokeAt(q + o2);
    float3 flowed = (picture(q + o1) * a + picture(q + o2) * b + here * 0.02) / (a + b + 0.02);
    return lerp(here, flowed, m);
}

// The colour smoke takes at q: borrowed from the picture's own smoke around it (never from the
// robot, car or anything else that isn't smoke, which would leave ghost copies), or `fallback`
// where there's no smoke nearby.
float3 smokeLight(float2 q, float3 fallback) {
    float3 sum = 0;
    float w = 0.0;
    [unroll] for (int i = 0; i < 8; i++) {
        float a = i * 0.785 + 0.3;
        float2 o = float2(cos(a), sin(a)) * 90.0;
        float m = smokeAt(q + o);
        sum += picture(q + o) * m;
        w += m;
    }
    return lerp(fallback, sum / max(w, 0.001) * 1.5 + 0.03, saturate(w / 2.0));
}

// Soft swirling smoke of our own that drifts across the scene (0-1 density). `scale` is the size
// of its billows in picture pixels; `drift` moves it, in picture pixels per second.
float smokeDensity(float2 q, float t, float2 drift, float scale) {
    float2 uv = (q - drift * t) / scale;
    float2 w1 = float2(fbm3(uv + float2(0.0, t * 0.04)), fbm3(uv + float2(5.2, 1.3) - t * 0.035));
    float2 w2 = float2(fbm3(uv + 3.5 * w1 + float2(1.7, 9.2) + t * 0.025), fbm3(uv + 3.5 * w1 + float2(8.3, 2.8)));
    float n = fbm3(uv * 1.3 + 3.5 * w2);
    return smoothstep(0.38, 0.9, n);
}

// Thin wisps that rise and drift through smoke (0-1), to add on top in the smoke's own colour.
float smokeWisps(float2 q, float t) {
    float2 w = q / 120.0 + float2(t * 0.02, t * 0.06);
    float2 warp = float2(fbm3(w + 1.3), fbm3(w + 7.1)) - 0.5;
    float n = fbm3(w * 1.6 + warp * 2.5 - float2(0.0, t * 0.05));
    return smoothstep(0.45, 0.85, n);
}

// Glowing embers drifting up and flickering out. p in screen-height units; one layer.
float3 embers(float2 p, float t, float cell, float speed, float size, float density, float seed, float px, float3 color) {
    float2 g = (p - float2(0.0, speed * t)) / cell;
    float2 id = floor(g);
    if (hash21(id + seed) > density) return 0;
    float r1 = hash21(id + seed + 1.0), r2 = hash21(id + seed + 2.0), r3 = hash21(id + seed + 3.0);
    float2 c = id + 0.5 + (float2(r1, r2) - 0.5) * 0.4;
    c.x += 0.2 * sin(t * (0.6 + r3) + r1 * 6.28) + 0.08 * sin(t * 2.3 + r2 * 9.0);
    float d = length((g - c) * cell);
    float s = size * (0.5 + r3);
    float life = 0.5 + 0.5 * sin(t * (0.5 + 0.7 * r2) + r1 * 20.0);  // each one brightens and fades
    float flicker = 0.7 + 0.3 * sin(t * (9.0 + 6.0 * r1) + r2 * 30.0);
    float core = exp(-d * d / (2.0 * max(s, px) * max(s, px)));
    float glow = exp(-d / (s * 4.0 + px)) * 0.25;
    return color * (core + glow) * life * life * flicker;
}

// Rain: thin slanted streaks falling past the camera. p in screen-height units; one layer.
// Returns brightness (0-1).
float rain(float2 p, float t, float cell, float speed, float len, float density, float seed, float slant, float px) {
    float2 dir = normalize(float2(slant, -1.0));
    float2 g = (p - dir * speed * t) / cell;
    float2 id = floor(g);
    float h = hash21(id + seed);
    if (h > density) return 0;
    float2 c = id + 0.5 + (float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0)) - 0.5) * 0.3;
    float2 d = (g - c) * cell;
    float along = dot(d, dir), across = dot(d, float2(-dir.y, dir.x));
    float streak = exp(-across * across / (2.0 * px * px * 0.5)) * smoothstep(len * 0.5, len * 0.3, abs(along));
    return streak * (0.35 + 0.65 * hash21(id + seed + 3.0)) * smoothstep(len * 0.5, -len * 0.5, along);
}

// Rings spreading on flat water, drawn in the water's own plane so they flatten with distance.
// horizonY: picture y of the far edge of the water; centerX: middle of the view; cell: ring
// spacing in the water plane; chance: share of cells with rings; period: (min, max) seconds
// between rings; life: how long a ring lasts; speed: how fast it grows. Returns (brightness,
// outward push).
float2 waterRings(float2 q, float t, float horizonY, float centerX, float cell, float chance, float2 period, float life, float speed) {
    float depth = 240.0 / max(q.y - horizonY + 10.0, 1.0);  // 1 at the bottom, larger far away
    float2 w = float2((q.x - centerX) * depth / 240.0, depth);
    float2 cellId = floor(w / cell);
    float width = (0.025 * depth + 0.02) * cell / 1.2;
    float bright = 0.0, push = 0.0;
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 id = cellId + float2(i, j);
        if (hash21(id + 4.0) > chance) continue;
        float per = lerp(period.x, period.y, hash21(id + 1.0));
        float lt = frac(t / per + hash21(id + 2.0)) * per;
        if (lt > life) continue;
        float2 c = (id + 0.2 + 0.6 * float2(hash21(id + 3.0), hash21(id + 5.0))) * cell;
        float r = length(w - c);
        float radius = lt * speed;
        float ring = exp(-pow((r - radius) / width, 2.0)) * (1.0 - lt / life);
        bright += ring;
        push += ring * sign(r - radius);
    }
    return float2(bright, push);
}

// Dust motes floating in the light: soft points drifting slowly every way, some large and out of
// focus. p in screen-height units; one layer. Returns brightness (0-1+).
float motes(float2 p, float t, float cell, float size, float density, float seed, float px) {
    float2 g = (p + float2(sin(t * 0.05 + seed), t * 0.008)) / cell;
    float2 id = floor(g);
    if (hash21(id + seed) > density) return 0;
    float r1 = hash21(id + seed + 1.0), r2 = hash21(id + seed + 2.0), r3 = hash21(id + seed + 3.0);
    float2 c = id + 0.5 + 0.3 * float2(sin(t * (0.13 + 0.2 * r1) + r2 * 6.28), cos(t * (0.11 + 0.2 * r2) + r1 * 6.28));
    float d = length((g - c) * cell);
    float s = max(size * (0.4 + r3), px);
    float shine = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(t * (0.6 + r1) + r3 * 20.0), 3.0);  // turns to catch the light
    return (exp(-d * d / (2.0 * s * s)) + exp(-d / (s * 3.0)) * 0.2) * shine;
}

// A small round twinkle for bright points (wet drops, glints): cells of `cell` picture pixels.
float twinkle(float2 q, float t, float cell, float sharpness) {
    float2 id = floor(q / cell);
    float tw = pow(0.5 + 0.5 * sin(t * (1.0 + 2.5 * hash21(id)) + hash21(id + 3.0) * 40.0), sharpness);
    return tw * smoothstep(0.45, 0.1, length(frac(q / cell) - 0.5));
}
