// Ring moon: a ring of moon rock, cratered and grey, set between thin silver rims. The rock band
// slowly turns inside its rims while the light on it stays put, so its craters travel round, and
// glints of light slide along the polished silver.
// texture: assets/ring_moon.jpg
// texture1: assets/ring_moon_fx.png
// scale: 1
// aspect: 0.45
#include "ring.hlsli"

static const float2 kCenter = float2(1016.0, 1011.0);  // picture pixels
static const float kInner = 800.0, kOuter = 943.0;
static const float kRockIn = 827.0, kRockOut = 917.0;   // the rock band, between the rims

// The light on the ring (the picture blurred); the picture over it is the rock's own detail.
float3 light(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float3 surface(float2 q) { return (picture(q) + 0.015) / (light(q) + 0.015); }

float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = ringPoint(fragCoord, kCenter, kOuter);
    float2 pr = polar(q, kCenter);
    float3 col = picture(q);

    // The rock band turns once every 80 seconds, its craters moving under the fixed light.
    float band = smoothstep(kRockIn - 4.0, kRockIn + 4.0, pr.y) * smoothstep(kRockOut + 4.0, kRockOut - 4.0, pr.y);
    if (band > 0.0) {
        float2 src = kCenter + rot(q - kCenter, -t * 0.078);
        col = lerp(col, light(q) * surface(src), band);
    }

    // Glints slide along the silver rims (outside the rock band).
    float rims = smoothstep(kInner - 10.0, kInner, pr.y) * (1.0 - band) * smoothstep(kOuter + 10.0, kOuter, pr.y);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float glide = nearAngle(pr.x, t * 0.9, 0.12) + nearAngle(pr.x, -t * 0.6 + 2.0, 0.1);
    col += float3(0.85, 0.92, 1.0) * glide * rims * smoothstep(0.2, 0.6, lum) * 0.9;
    col += float3(0.9, 0.95, 1.0) * twinkle(q, t, 6.0, 36.0) * rims * smoothstep(0.35, 0.7, lum) * 0.5;
    return float4(col, 1.0);
}
