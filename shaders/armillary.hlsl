// Armillary sphere: steel rings round a glowing core. Light sweeps round the rings as they spin, the
// outer ones one way and the inner ones the other; the core pulses with energy, rippling outward
// from its heart, sparks orbit inside its glass, and its orange light flickers on the metal.
// texture: assets/armillary.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float2 kCore = float2(1280.0, 418.0); // the glowing core
static const float kGlass = 112.0;                 // radius of the glass sphere round it

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// How much a colour is bare steel (bright, without colour), and how much it's the core's orange.
float steel(float3 c) {
    float mx = max(c.r, max(c.g, c.b));
    return smoothstep(0.25, 0.6, mx) * (1.0 - smoothstep(0.12, 0.3, (mx - min(c.r, min(c.g, c.b))) / max(mx, 0.02)));
}
float orange(float3 c) { return saturate(((c.r - c.b) / max(c.r, 0.02) - 0.5) * 2.5) * smoothstep(0.2, 0.6, c.r); }

// Sparks orbiting inside the glass on tilted paths, each with a short fading trail.
float3 orbitSparks(float2 q, float t) {
    float3 col = 0;
    [unroll] for (int i = 0; i < 6; i++) {
        float h = hash21(float2(i, 7.0));
        float radius = 32.0 + 62.0 * hash21(float2(i, 3.0));
        float tilt = (h - 0.5) * 2.4;
        float flat = 0.25 + 0.3 * hash21(float2(i, 5.0));
        float speed = (1.6 + 1.6 * hash21(float2(i, 9.0))) * (i % 2 == 0 ? 1.0 : -1.0);
        [unroll] for (int k = 0; k < 6; k++) {  // the spark and its trail
            float a = t * speed - k * 0.07 * sign(speed) + h * 6.28;
            float2 pos = kCore + rot(float2(cos(a), sin(a) * flat) * radius, tilt);
            float d = length(q - pos);
            float front = sin(a) > 0.0 ? 1.0 : 0.55;  // dimmer behind the core
            float glow = k == 0 ? exp(-d * d / 7.0) * 1.6 + exp(-d / 6.0) * 0.3 : exp(-d * d / 4.0) * 0.6 * (1.0 - k / 6.0);
            col += float3(1.0, 0.75, 0.4) * glow * front;
        }
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
    float2 d = q - kCore;
    float r = length(d);
    float a = atan2(d.y, d.x);

    // The core's power: a slow pulse with a fast flicker.
    float power = 0.75 + 0.25 * sin(t * 1.3) + 0.08 * (noise(float2(t * 9.0, 1.0)) - 0.5);

    // Energy ripples outward from the heart of the core.
    float glassW = smoothstep(kGlass, kGlass - 10.0, r);
    float ripple = pow(0.5 + 0.5 * sin(r / 10.0 - t * 4.5), 4.0) * exp(-r / 95.0);
    float o = orange(col);
    col += col * o * glassW * (2.4 * ripple + 0.9 * (power - 0.75));
    col += float3(1.0, 0.6, 0.2) * exp(-r / 18.0) * 0.45 * power;  // the hot centre
    col += float3(1.0, 0.5, 0.15) * exp(-r / 120.0) * 0.06 * power;

    // Its orange light on the metal flickers with it.
    col += col * o * (1.0 - glassW) * (power - 0.75) * 1.2;

    // Light sweeps round the rings as they spin: outer rings one way, inner rings the other.
    float s = steel(col);
    float outer = smoothstep(250.0, 300.0, r), inner = smoothstep(300.0, 250.0, r) * smoothstep(kGlass, kGlass + 30.0, r);
    float sweepOuter = pow(0.5 + 0.5 * cos(a - t * 0.55), 14.0) + pow(0.5 + 0.5 * cos(a - t * 0.55 + 3.1416), 14.0) * 0.6;
    float sweepInner = pow(0.5 + 0.5 * cos(a + t * 0.9 + 1.0), 14.0) + pow(0.5 + 0.5 * cos(a + t * 0.9 + 4.1), 14.0) * 0.6;
    float sweep = sweepOuter * outer + sweepInner * inner;
    col *= 1.0 - s * 0.25 * (1.0 - saturate(sweep * 1.6));  // the rings dim away from the light
    col += (col * 1.4 + 0.1) * s * sweep * 1.1;
    // The screws and studs catch the light now and then.
    col += float3(1.0, 0.95, 0.85) * twinkle(q, t, 5.0, 40.0) * smoothstep(0.6, 0.85, max(col.r, max(col.g, col.b))) * 0.7;

    // (hidden where the inner ring passes in front of the glass)
    float ringBand = smoothstep(386.0, 394.0, q.y) * smoothstep(482.0, 474.0, q.y);
    if (r < kGlass + 6.0) col += orbitSparks(q, t) * glassW * (1.0 - ringBand);
    return float4(col, 1.0);
}
