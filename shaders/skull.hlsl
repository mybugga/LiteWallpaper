// Skull: a skull wreathed in smoke, white on one side and lit red on the other. The smoke streams up
// and curls away from it with more drifting through, the red light flickers like firelight, a
// faint ember glow breathes deep in the eye sockets, and a few embers rise through the red smoke.
// texture: assets/skull.jpg
// texture1: assets/skull_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kCentre = float2(838.0, 430.0);
static const float2 kEyeL = float2(700.0, 352.0);
static const float2 kEyeR = float2(975.0, 352.0);

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = the skull, g = where there's smoke around it.
float2 regions(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rg; }
float smokeMask(float2 q) { return 1.0 - regions(q).r; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float2 reg = regions(q);
    float skull = reg.r;

    // The smoke streams up and away from the skull on both sides, with wisps rising through it.
    float side = q.x < kCentre.x ? -1.0 : 1.0;
    float3 col = streamSmoke(q, t, float2(side * 6.0, -15.0));
    col += col * (1.0 - skull) * smokeWisps(q, t) * 0.45;

    // More smoke drifting up through it, in the colour of the smoke around it.
    float region = saturate(reg.g * 1.3) * (1.0 - skull);
    if (region > 0.01) {
        float d = smokeDensity(q, t, float2(side * 4.0, -18.0), 170.0) * region;
        col += smokeLight(q, float3(0.08, 0.08, 0.09)) * d * 0.75;
    }

    // The red light flickers like a fire just out of view, on the skull and the smoke alike.
    float flicker = 1.0 + 0.32 * (noise(float2(t * 3.1, 1.0)) - 0.5) + 0.12 * (noise(float2(t * 9.0, 4.0)) - 0.5);
    float redness = saturate((col.r - max(col.g, col.b)) * 3.0);
    col += col * redness * (flicker - 1.0) * 1.4;

    // Embers glowing deep in the eye sockets, breathing slowly.
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float dark = smoothstep(0.22, 0.04, lum) * skull;
    float breathe = 0.55 + 0.45 * sin(t * 0.9);
    [unroll] for (int i = 0; i < 2; i++) {
        float2 e = i == 0 ? kEyeL : kEyeR;
        float r = length((q - e) / float2(62.0, 54.0));
        float glow = exp(-r * r * 3.0) * 0.16 + exp(-r * r * 30.0) * 0.12;
        col += float3(1.0, 0.12, 0.03) * glow * breathe * flicker * dark;
    }

    // A few embers rise through the red smoke.
    float right = smoothstep(0.52, 0.68, p.x / aspect);
    col += embers(p, t, 0.08, 0.045, 0.0011, 0.2, 7.0, px, float3(1.0, 0.18, 0.06)) * right;
    col += embers(p, t, 0.13, 0.07, 0.0017, 0.15, 19.0, px, float3(1.0, 0.25, 0.08)) * right * 0.8;
    return float4(col, 1.0);
}
