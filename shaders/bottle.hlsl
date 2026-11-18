// Storm bottle: a thunderstorm trapped in a corked glass bottle. Lightning strikes every few
// seconds with a real stroke's flicker (a flash, quick re-strikes, an afterglow): sometimes the
// bolt from the picture, sometimes a new branching bolt somewhere else. Each strike lights the
// clouds from inside, the glass and the reflection on the table; sheet lightning glows inside the
// clouds in between; rain falls inside the glass, and the clouds and the swirl at the bottom churn.
// texture: assets/bottle.jpg
// texture1: assets/bottle_light.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float4 kInside = float4(948.0, 205.0, 1416.0, 792.0);  // inside the glass: x0, y0, x1, y1
static const float kCloudBase = 425.0;
static const float kStormFloor = 745.0;

float3 storm(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }      // between strikes
float3 boltLight(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }  // the painted bolt's light
float3 picture(float2 q) { return storm(q); }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float inside(float2 q, float soft) {
    return smoothstep(kInside.x, kInside.x + soft, q.x) * smoothstep(kInside.z, kInside.z - soft, q.x) *
           smoothstep(kInside.y, kInside.y + soft, q.y) * smoothstep(kInside.w, kInside.w - soft, q.y);
}

// One lightning strike in each `slot` seconds, at a random moment: the brightness over time of a
// real stroke, with a faint leader, re-strikes and an afterglow. Also returns which slot it was.
float strike(float t, float slot, float seed, out float id) {
    id = floor(t / slot);
    float t0 = (id + 0.12 + 0.6 * hash21(float2(id, seed))) * slot;
    float dt = t - t0;
    if (dt < -0.06 || dt > 1.6) return 0.0;
    float e = step(-0.05, dt) * step(dt, 0.0) * 0.25;
    e = max(e, step(0.0, dt) * exp(-dt / 0.06));
    e = max(e, step(0.1, dt) * 0.7 * exp(-(dt - 0.1) / 0.05));
    e = max(e, step(0.24, dt) * 0.95 * exp(-(dt - 0.24) / 0.1));
    if (hash21(float2(id, seed + 9.0)) > 0.45) e = max(e, step(0.52, dt) * 0.55 * exp(-(dt - 0.52) / 0.08));
    return e + step(0.0, dt) * 0.12 * exp(-dt / 0.5);
}

// A jagged line down through y: a slow meander plus straight zig-zags, like a real bolt.
float boltX(float y, float x0, float seed) {
    float a = y / 75.0, b = y / 13.0;
    float slow = lerp(hash21(float2(floor(a), seed)), hash21(float2(floor(a) + 1.0, seed)), smoothstep(0.0, 1.0, frac(a)));
    float jag = lerp(hash21(float2(floor(b), seed + 5.0)), hash21(float2(floor(b) + 1.0, seed + 5.0)), frac(b));
    return x0 + (slow - 0.5) * 110.0 + (jag - 0.5) * 16.0;
}

// A new bolt from the cloud base to the bottom of the storm at x0, with a few branches.
float newBolt(float2 q, float x0, float seed) {
    if (q.y < kCloudBase - 90.0 || q.y > kStormFloor + 140.0) return 0.0;
    float d = abs(q.x - boltX(q.y, x0, seed));
    float along = saturate((q.y - kCloudBase + 25.0) / (kStormFloor - kCloudBase + 25.0));
    // It comes out of the cloud base: fade it in there, and out below the storm's floor.
    float span = smoothstep(kCloudBase - 80.0, kCloudBase - 15.0, q.y) * smoothstep(kStormFloor + 25.0, kStormFloor, q.y);
    float v = (exp(-d * d / 4.0) * 1.8 + exp(-d / 8.0) * 0.55 + exp(-d / 40.0) * 0.2) * (0.75 + 0.25 * along) * span;
    [unroll] for (int i = 0; i < 4; i++) {
        float y0 = lerp(kCloudBase + 10.0, kStormFloor - 90.0, (i + hash21(float2(i, seed + 2.0))) / 4.0);
        float len = 60.0 + 80.0 * hash21(float2(i, seed + 3.0));
        if (q.y < y0 || q.y > y0 + len) continue;
        float dir = hash21(float2(i, seed + 4.0)) > 0.5 ? 1.0 : -1.0;
        float k = (q.y - y0) / len;
        float bx = boltX(y0, x0, seed) + dir * (q.y - y0) * (0.6 + 0.6 * hash21(float2(i, seed + 6.0))) +
                   (hash21(float2(floor(q.y / 9.0), seed + i * 7.0)) - 0.5) * 8.0 * k;
        float db = abs(q.x - bx);
        v += (exp(-db * db / 2.0) * 1.2 + exp(-db / 6.0) * 0.35) * (1.0 - k * 0.8);
    }
    // It lights up the storm where it hits the bottom.
    float2 hit = (q - float2(boltX(kStormFloor, x0, seed), kStormFloor)) / float2(90.0, 40.0);
    v += exp(-dot(hit, hit)) * 0.7;
    return v;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float inner = inside(q, 14.0);

    // The clouds and the swirl at the bottom churn.
    float cloud = smoothstep(180.0, 240.0, q.y) * smoothstep(470.0, 410.0, q.y);
    float swirl = smoothstep(610.0, 660.0, q.y) * smoothstep(800.0, 770.0, q.y);
    float2 qs = q + smokeFlow(q, t * 1.6) * (cloud * 0.55 + swirl * 0.4) * inner;
    float3 col = storm(qs);

    // Strikes: about every five seconds, either the painted bolt or a new one somewhere else.
    float id;
    float e = strike(t, 5.0, 1.0, id);
    bool painted = hash21(float2(id, 4.0)) < 0.45;
    float x0 = lerp(1060.0, 1330.0, hash21(float2(id, 6.0)));
    float sheetId;
    float sheet = strike(t, 1.9, 21.0, sheetId) * step(hash21(float2(sheetId, 22.0)), 0.4) * 0.45;
    float2 sheetAt = float2(lerp(1010.0, 1380.0, hash21(float2(sheetId, 23.0))), lerp(260.0, 400.0, hash21(float2(sheetId, 24.0))));

    float3 blue = float3(0.75, 0.9, 1.15);
    float flash = 0.0;
    if (painted) {
        col += boltLight(qs) * e * 1.15;
        flash = e;
    } else {
        // A new bolt, lighting the storm round it.
        float b = newBolt(q, x0, id * 3.7 + 1.0);
        col += float3(0.8, 0.92, 1.0) * b * e * inner;
        float nearBolt = 0.55 + 0.7 * exp(-abs(q.x - x0) / 170.0);
        col += storm(qs) * blue * e * nearBolt * 1.3 * inner;
        flash = e;
    }
    // Sheet lightning glows inside the clouds.
    float sheetGlow = exp(-length((q - sheetAt) / float2(170.0, 90.0)));
    col += storm(qs) * blue * sheet * sheetGlow * 2.5 * cloud * inner;
    float lit = max(flash, sheet * 0.5);

    // Rain inside the glass, catching the light.
    float rainArea = inner * smoothstep(kCloudBase - 20.0, kCloudBase + 30.0, q.y) * smoothstep(780.0, 740.0, q.y);
    if (rainArea > 0.01) {
        float r = rain(p, t, 0.03, 0.9, 0.028, 0.45, 3.0, 0.1, px) + rain(p, t, 0.045, 1.2, 0.04, 0.35, 8.0, 0.1, px * 1.3);
        col += float3(0.55, 0.7, 0.85) * r * rainArea * (0.16 + 1.1 * lit);
    }

    // The glass, its droplets and the reflection on the table flash too.
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float glass = (1.0 - inner) * smoothstep(890.0, 930.0, q.x) * smoothstep(1475.0, 1440.0, q.x) * step(q.y, 815.0);
    col += storm(q) * blue * lit * (glass * 0.9 + inner * 0.1);
    float table = smoothstep(800.0, 830.0, q.y) * smoothstep(860.0, 1000.0, q.x) * smoothstep(1520.0, 1420.0, q.x);
    col += storm(q) * blue * lit * table * 1.6;
    return float4(col, 1.0);
}
