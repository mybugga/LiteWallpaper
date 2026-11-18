// Manta ray: a glowing manta gliding through the dark sea. Its wings flap slowly with the bend
// travelling out to the tips and its tail trails after; waves of light run out along its glowing
// edges, the specks on its wings twinkle, glowing particles shed from its wings drift away in its
// wake, and plankton drifts past.
// texture: assets/manta.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);      // picture pixels the positions below use
static const float2 kBody = float2(1180.0, 505.0);     // middle of the body
static const float2 kRootL = float2(1040.0, 515.0);    // where each wing (and the tail) starts...
static const float2 kTipL = float2(770.0, 548.0);      // ...and ends
static const float2 kRootR = float2(1330.0, 440.0);
static const float2 kTipR = float2(1642.0, 84.0);
static const float2 kRootT = float2(1385.0, 640.0);
static const float2 kTipT = float2(1655.0, 792.0);
static const float kBeat = 6.2832 / 3.8;               // one flap every 3.8 seconds

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// How much a colour is the manta's cyan glow.
float glow(float3 c) { return saturate((c.b - c.r) * 3.0) * smoothstep(0.15, 0.5, max(c.g, c.b)); }

// How far a limb bends at q, and how far along it q is (0 at its root, 1 at its tip). The bend
// grows towards the tip and lags behind there, so it travels outward like a real wing beat.
float2 limbBend(float2 q, float2 root, float2 tip, float amp, float lag, float phase, float t, out float along) {
    float2 u = normalize(tip - root);
    float len = length(tip - root);
    along = saturate(dot(q - root, u) / len);
    float side = smoothstep(0.45, 0.8, dot(normalize(q - kBody), normalize(tip - kBody)));  // only this limb's side
    float2 n = float2(-u.y, u.x);
    return n * amp * pow(along, 1.6) * sin(t * kBeat + phase - lag * along) * side;
}

// Glowing particles shed from the wings' edges, drifting back in the manta's wake and fading.
float3 wake(float2 q, float t, float cell, float size, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int dy = -1; dy <= 0; dy++)
    [unroll] for (int dx = -2; dx <= 0; dx++) {
        float2 id = base + float2(dx, dy);
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float period = 2.5 + 2.0 * hash21(id + seed + 3.0);
        float life = period * 0.9;
        float2 v = float2(18.0 + 14.0 * hash21(id + seed + 5.0), 6.0 + 6.0 * hash21(id + seed + 6.0));
        v *= min(1.0, 1.8 * cell / (length(v) * life));
        float2 rel = q - spawn;
        float ta = clamp(dot(rel, v) / dot(v, v), 0.0, life);
        if (length(rel - v * ta) > 10.0) continue;
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        if (age > life || glow(picture(spawn)) < 0.5) continue;
        float2 pos = spawn + v * age + float2(0.0, 3.0 * sin(age * 1.7 + seed));
        float d = length(q - pos);
        float s = size * (0.6 + 0.8 * hash21(id + seed + 7.0));
        float fade = smoothstep(0.0, 0.3, age) * pow(1.0 - age / life, 1.5);
        col += float3(0.35, 0.85, 1.0) * (exp(-d * d / (2.0 * s * s)) * 1.2 + exp(-d / (s * 3.5)) * 0.3) * fade * smoothstep(10.0, 6.0, d);
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

    // The wings flap and the tail trails; the body rises a little as the wings come down.
    float aL, aR, aT;
    float2 bend = limbBend(q, kRootL, kTipL, 30.0, 1.4, 0.0, t, aL)
                + limbBend(q, kRootR, kTipR, 38.0, 1.4, 0.0, t, aR)
                + limbBend(q, kRootT, kTipT, 16.0, 2.0, -1.2, t, aT);
    float near = smoothstep(820.0, 600.0, length(q - kBody));
    float2 bob = float2(0.0, 4.0 * sin(t * kBeat + 3.1416)) * near;
    float2 qs = q - bend - bob;
    float3 col = picture(qs);

    // Waves of light run out along the glowing edges, from the body to the tips.
    float g = glow(col);
    float along = max(max(aL, aR), aT);
    float wave = pow(0.5 + 0.5 * sin(along * 14.0 - t * 2.6), 3.0);
    col += col * g * (0.9 * wave + 0.25 * (0.5 + 0.5 * sin(t * kBeat)));
    // The specks on the wings twinkle.
    col += float3(0.5, 0.95, 1.0) * twinkle(qs, t, 3.0, 24.0) * smoothstep(0.3, 0.6, max(col.g, col.b)) * 0.6;

    // Glowing particles shed in its wake, and plankton drifting past.
    if (q.x > 700.0) {
        col += wake(q, t, 40.0, 1.3, 1.0);
        col += wake(q, t, 55.0, 1.9, 17.0) * 0.8;
    }
    float plankton = motes(p + float2(-t * 0.004, 0.0), t, 0.05, 0.0012, 0.3, 5.0, px) +
                     motes(p + float2(-t * 0.008, 0.0), t, 0.09, 0.0026, 0.2, 13.0, px) * 0.7;
    col += float3(0.3, 0.75, 1.0) * plankton * 0.45;
    return float4(col, 1.0);
}
