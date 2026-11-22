// Whale island: a humpback whale swimming through the dark with a forest growing on its back. It
// drifts and rolls gently as it swims, its long flippers stroking and its flukes sweeping; the
// waterfalls pour off the cliffs on its side into mist, fog drifts through the pines, the cabin's
// window glows warm and flickers, and the blue-green lights on its skin twinkle.
// texture: assets/whale_island.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

static const float2 kBody = float2(1024.0, 900.0);       // picture pixels: it rolls about here
static const float2 kFinRoot = float2(1060.0, 1080.0);   // the near flipper
static const float2 kFinTip = float2(220.0, 1980.0);
static const float2 kFin2Root = float2(1420.0, 1200.0);  // the far flipper
static const float2 kFin2Tip = float2(1920.0, 1600.0);
static const float2 kFlukeRoot = float2(330.0, 600.0);   // the tail stock
static const float2 kWindow = float2(1130.0, 650.0);     // the cabin's lit window

// How much of a limb a point is: 0 at its root, 1 out along it, 0 away to the side.
float limb(float2 q, float2 root, float2 tip, float halfWidth) {
    float2 ax = tip - root;
    float s = dot(q - root, ax) / dot(ax, ax);
    float n = abs(dot(q - root, float2(-ax.y, ax.x))) / length(ax);
    return smoothstep(0.02, 0.3, s) * smoothstep(1.15, 1.0, s) * smoothstep(halfWidth * 1.25, halfWidth * 0.8, n);
}

// A waterfall from `top` to `bottom`, `width` wide: how much of it a point is, and how far down it.
float2 fall(float2 q, float2 top, float2 bottom, float width) {
    float2 ax = bottom - top;
    float L = length(ax);
    float s = dot(q - top, ax) / (L * L);
    float n = abs(dot(q - top, float2(-ax.y, ax.x))) / L;
    return float2(smoothstep(-0.01, 0.06, s) * smoothstep(1.05, 0.85, s) * smoothstep(width * 0.55, width * 0.3, n), s);
}

// Water streaming down a fall: the picture slides down along it, two copies half a cycle apart
// blended so it never jumps back.
float3 flowing(float2 q, float2 dir, float t, float speed) {
    float ph = frac(t * speed);
    float ph2 = frac(t * speed + 0.5);
    float3 a = picture(q - dir * ph * 46.0);
    float3 b = picture(q - dir * ph2 * 46.0);
    return lerp(a, b, abs(ph * 2.0 - 1.0));
}

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q0 = squarePoint(fragCoord, 0.95);

    // Swimming: a slow drift up and down, a slight roll, the flippers stroking and the flukes sweeping.
    float swim = sin(t * 0.62);
    float2 q = kBody + rot(q0 - kBody, -0.011 * sin(t * 0.43)) - float2(0.0, 9.0 * sin(t * 0.37));
    float f1 = limb(q, kFinRoot, kFinTip, 270.0);
    q = lerp(q, kFinRoot + rot(q - kFinRoot, -0.045 * swim), f1);
    float f2 = limb(q, kFin2Root, kFin2Tip, 200.0);
    q = lerp(q, kFin2Root + rot(q - kFin2Root, 0.035 * swim), f2);
    float fluke = smoothstep(560.0, 380.0, q.y) * smoothstep(820.0, 700.0, q.x) * smoothstep(0.0, 60.0, q.x);
    q = lerp(q, kFlukeRoot + rot(q - kFlukeRoot, 0.03 * sin(t * 0.62 + 1.2)), fluke);

    float3 col = picture(q);

    // The waterfalls pour, three drops of them, the water streaming down each.
    float2 w1 = fall(q, float2(367.0, 740.0), float2(300.0, 1013.0), 42.0);
    float2 w2 = fall(q, float2(603.0, 783.0), float2(567.0, 940.0), 44.0);
    float2 w3 = fall(q, float2(567.0, 940.0), float2(533.0, 1240.0), 34.0);
    if (w1.x + w2.x + w3.x > 0.001) {
        float2 d1 = normalize(float2(300.0, 1013.0) - float2(367.0, 740.0));
        float2 d2 = normalize(float2(567.0, 940.0) - float2(603.0, 783.0));
        float2 d3 = normalize(float2(533.0, 1240.0) - float2(567.0, 940.0));
        col = lerp(col, flowing(q, d1, t, 0.9), w1.x);
        col = lerp(col, flowing(q, d2, t, 1.0), w2.x);
        col = lerp(col, flowing(q, d3, t, 0.85), w3.x);
        // Bright streaks running down the water.
        float streak = pow(noise(float2(q.x / 3.0, q.y / 40.0 - t * 5.0)), 4.0);
        col += float3(0.8, 0.9, 0.95) * streak * max(w1.x, max(w2.x, w3.x)) * 0.35;
    }

    // Mist where the falls land, and fog drifting through the trees (where the picture is misty).
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float sat = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));
    float misty = smoothstep(0.3, 0.55, lum) * smoothstep(0.2, 0.05, sat) * smoothstep(1050.0, 900.0, q.y) * smoothstep(1500.0, 1300.0, q.x);
    float drift = fbm3(float2(q.x / 220.0 - t * 0.06, q.y / 140.0 + t * 0.02));
    col += float3(0.72, 0.8, 0.82) * (misty * (drift - 0.45) * 0.45);
    float spray = exp(-length((q - float2(305.0, 1000.0)) * float2(1.0, 1.6)) / 70.0) + exp(-length((q - float2(538.0, 1220.0)) * float2(1.0, 1.6)) / 60.0);
    col += float3(0.75, 0.85, 0.9) * spray * (0.12 + 0.1 * fbm(q / 40.0 + float2(0.0, -t * 0.8)));

    // The cabin's window glows warm and flickers, its light spilling a little round it.
    float rw = length(q - kWindow);
    float flicker = 0.85 + 0.1 * sin(t * 7.3) * sin(t * 3.1 + 1.0) + 0.06 * noise(float2(t * 4.0, 0.0));
    float warm = saturate((col.r - col.b) * 3.0) * smoothstep(0.3, 0.6, lum) * smoothstep(40.0, 20.0, rw);
    col *= 1.0 + warm * (flicker - 0.85) * 2.0;
    col += float3(1.0, 0.55, 0.2) * exp(-rw / 28.0) * 0.12 * flicker;

    // The blue-green lights in its skin twinkle.
    float glowy = saturate((col.g + col.b - 2.0 * col.r) * 2.5 - 0.45) * smoothstep(0.35, 0.7, lum) * (1.0 - misty);
    col += float3(0.4, 0.95, 1.0) * twinkle(q, t, 8.0, 30.0) * glowy * 0.8;
    return float4(col, 1.0);
}
