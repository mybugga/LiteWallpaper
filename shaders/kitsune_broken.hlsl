// Kitsune broken: a white fox mask, cracked and mended with gold, one ear shattered. Red smoke
// streams out of the break and curls away with embers glowing and drifting in it, fire flickers in
// the break, light runs along the gold seams, the broken shards drift, and the tassel sways on its
// cord while the ribbon ripples.
// texture: assets/kitsune_broken.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"

static const float2 kBreak = float2(1120.0, 730.0);   // picture pixels: where the fire is
static const float2 kBead = float2(1320.0, 1370.0);   // the tassel hangs from here
static const float3 kShards[3] = { float3(1520.0, 205.0, 55.0), float3(1380.0, 360.0, 48.0), float3(1410.0, 500.0, 26.0) };

// The red smoke: right of the break and the broken ear, red rather than white (the shards) or the
// mask's own red paint (it's left of this).
float smokeMask(float2 q) {
    float edge = lerp(1490.0, 1235.0, smoothstep(470.0, 640.0, q.y));
    float region = smoothstep(edge - 15.0, edge + 25.0, q.x) * smoothstep(940.0, 860.0, q.y) * smoothstep(40.0, 90.0, q.y);
    float3 c = picture(q);
    float red = saturate((c.r - max(c.g, c.b)) * 3.0);
    return region * smoothstep(0.08, 0.3, red);
}
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = squarePoint(fragCoord, 0.95);

    // The shards drift, each on its own slow path.
    [unroll] for (int k = 0; k < 3; k++) {
        float fk = (float)k;
        float2 off = float2(sin(t * (0.4 + 0.1 * fk) + fk * 2.0), cos(t * (0.33 + 0.07 * fk) + fk)) * (5.0 + 2.0 * fk);
        float w = smoothstep(kShards[k].z + 18.0, kShards[k].z, length(q - kShards[k].xy - off));
        q -= off * w;
    }

    // The tassel swings gently below its bead; the ribbon ripples.
    float tassel = smoothstep(1380.0, 1520.0, q.y) * smoothstep(1060.0, 1160.0, q.x);
    q = lerp(q, kBead + rot(q - kBead, 0.03 * sin(t * 0.8) + 0.01 * sin(t * 1.9)), tassel);
    float ribbon = (smoothstep(1300.0, 1400.0, q.y) * smoothstep(1150.0, 1050.0, q.x) + smoothstep(300.0, 220.0, q.x) * smoothstep(950.0, 1050.0, q.y)) * (1.0 - tassel);
    q += float2(sin(q.y / 70.0 - t * 1.6), sin(q.x / 80.0 - t * 1.4)) * 3.0 * saturate(ribbon);

    // The smoke streams away from the break, rightwards and then curling up.
    float2 drift = lerp(float2(26.0, -42.0), float2(55.0, -12.0), smoothstep(350.0, 650.0, q.y));
    float3 col = streamSmoke(q, t, drift);
    float smoke = smokeMask(q);
    col *= 1.0 + smoke * 0.25 * (smokeWisps(q, t) - 0.4);

    float lum = dot(col, float3(0.3, 0.55, 0.15));

    // Fire flickers in the break.
    float rb = length(q - kBreak);
    float flame = 0.75 + 0.25 * noise(float2(t * 6.0, 1.0)) + 0.1 * sin(t * 13.0);
    float hot = saturate((col.r - col.b) * 2.0) * smoothstep(0.35, 0.7, lum) * exp(-rb / 90.0);
    col *= 1.0 + hot * (flame - 0.8) * 1.6;
    col += float3(1.0, 0.45, 0.12) * exp(-rb / 45.0) * 0.18 * flame;

    // Light runs along the gold seams.
    float gold = saturate((min(col.r, col.g) - col.b) * 3.0) * smoothstep(0.45, 0.75, lum) * smoothstep(1600.0, 1300.0, q.x + q.y * 0.2);
    float run = pow(0.5 + 0.5 * sin(dot(q, float2(0.012, 0.009)) - t * 1.6 + noise(q / 90.0) * 2.5), 8.0);
    col += float3(1.0, 0.8, 0.35) * gold * (0.12 + 0.6 * run);

    // Embers glow and drift up through the smoke.
    float2 p = q / kImg.y;
    float ember = smoothstep(0.2, 0.6, smoke);  // only in the smoke, like the picture's own
    col += embers(p, t, 0.035, 0.03, 0.0016, 0.45, 3.0, 0.0005, float3(1.0, 0.5, 0.15)) * ember * 0.9;
    col += embers(p, t, 0.05, 0.022, 0.0024, 0.3, 8.0, 0.0005, float3(1.0, 0.65, 0.25)) * ember * 0.7;
    return float4(col, 1.0);
}
