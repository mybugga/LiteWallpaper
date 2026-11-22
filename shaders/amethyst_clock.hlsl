// Amethyst clock: a clock set into an amethyst geode on a bronze stand, showing the real time: its
// rose-gold hands turn with the time of day and the seconds hand ticks. Light glides across the
// crystals, glinting on their facets, and the violet glow inside the geode slowly swells and fades.
// texture: assets/amethyst_clock_plate.jpg
// texture1: assets/amethyst_clock_hands.png
// texture_portrait: assets/amethyst_clock_plate.jpg
// texture1_portrait: assets/amethyst_clock_hands.png
// aspect_portrait: 0.45
// focus_portrait: 0.5
// scale: 1
// focus: 0.576
static const float2 kImg = float2(2560.0, 1440.0);
#include "amethyst_clock_hands.hlsli"
#include "clock.hlsli"
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float3 f = framePoint(fragCoord, float3(1473.0, 707.0, 1240.0));
    float2 q = f.xy;
    float t = iTime;
    float3 col = plate(q);

    // The crystals: violet, lit, round the dial (not the dial, the rock or the black around).
    float r = length(q - kHub);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float crystal = smoothstep(kDialR + 22.0, kDialR + 45.0, r) * saturate((col.b - col.g) * 4.0) * smoothstep(0.06, 0.3, lum);

    // A soft band of light glides across the geode every 9 seconds, brightest on the facets.
    float2 dir = normalize(float2(1.0, -0.55));
    float sweep = (frac(t / 9.0) * 2.8 - 1.4) * 700.0;
    float band = exp(-pow((dot(q - kHub, dir) - sweep) / 150.0, 2.0));
    float facet = smoothstep(0.2, 0.6, lum);
    col *= 1.0 + crystal * (0.55 * band * (0.4 + facet) + 0.08 * sin(t * 0.55));

    // Glints on the facets, brighter as the light passes.
    col += float3(0.95, 0.85, 1.0) * twinkle(q, t, 10.0, 34.0) * crystal * smoothstep(0.35, 0.75, lum) * (0.6 + band);

    col = clockFace(q, col, iDate.w, float2(3.0, 4.0), 0.3);
    return float4(col * f.z, 1.0);
}
