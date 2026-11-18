// Mech: a black armoured robot in red smoke. The smoke streams up and away from it, more drifts in
// around it, the armour's red lights pulse like a heartbeat, a scan of light runs along the visor
// every few seconds, and embers drift up.
// texture: assets/mech.jpg
// texture1: assets/mech_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kVisorA = float2(868.0, 226.0);  // visor slit, from its back end...
static const float2 kVisorB = float2(1040.0, 332.0); // ...to its point

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = smoke, g = red lights on the armour, b = the visor slit.
float3 effects(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return effects(q).r; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 fx = effects(q);
    // The picture's smoke streams up and away from the robot on both sides.
    float3 col = streamSmoke(q, t, float2(q.x < 900.0 ? -7.0 : 7.0, -13.0));
    col += col * fx.r * smokeWisps(q, t) * 0.6;

    // More smoke drifts through, around the smoke that's there and low across the bottom.
    float around = max(max(effects(q + float2(90.0, 0.0)).r, effects(q - float2(90.0, 0.0)).r), effects(q + float2(0.0, 90.0)).r);
    float region = saturate(max(fx.r, around * 0.8) + smoothstep(700.0, 941.0, q.y) * 0.5);
    if (region > 0.01) {
        float d = smokeDensity(q, t, float2(9.0, -15.0), 230.0) * region;
        col += smokeLight(q, float3(0.07, 0.06, 0.065)) * d * 0.9;
    }

    // Red lights pulse in a double beat, with a slight electric flicker.
    float beat = frac(t / 2.2);
    float pulse = exp(-pow((beat - 0.1) / 0.05, 2.0)) + 0.6 * exp(-pow((beat - 0.3) / 0.06, 2.0));
    float flicker = 0.9 + 0.1 * noise(float2(t * 14.0, q.y / 40.0));
    col += col * fx.g * (0.25 + 0.6 * pulse) * flicker;

    // A scan of light runs along the visor every five seconds.
    float2 ab = kVisorB - kVisorA;
    float s = saturate(dot(q - kVisorA, ab) / dot(ab, ab));
    float sweep = frac(t / 5.0) * 1.8 - 0.4;
    float scan = exp(-pow((s - sweep) / 0.06, 2.0));
    col += (col + float3(0.4, 0.05, 0.05)) * scan * fx.b * 2.0;
    float2 dv = (q - lerp(kVisorA, kVisorB, 0.7)) / kImg.y;
    col += float3(1.0, 0.12, 0.08) * exp(-length(dv * float2(1.0, 2.0)) / 0.05) * (0.06 + 0.1 * pulse);

    // Embers rising through the scene.
    col += embers(p, t, 0.09, 0.05, 0.0012, 0.25, 3.0, px, float3(1.0, 0.25, 0.08));
    col += embers(p, t, 0.16, 0.08, 0.002, 0.2, 9.0, px, float3(1.0, 0.35, 0.1)) * 0.8;
    return float4(col, 1.0);
}
