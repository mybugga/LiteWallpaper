// Dragon clock: a green dragon asleep, curled round a bronze clock on a slab of slate. The clock shows
// the real time, its seconds hand ticking; the dragon breathes slowly in its sleep, and the
// fireflies about it drift and glow brighter and dimmer.
// texture: assets/dragon_clock_plate.jpg
// texture1: assets/dragon_clock_hands.png
// texture_portrait: assets/dragon_clock_plate.jpg
// texture1_portrait: assets/dragon_clock_hands.png
// aspect_portrait: 0.45
// focus_portrait: 0.5
// scale: 1
// focus: 0.55
static const float2 kImg = float2(2560.0, 1440.0);
#include "dragon_clock_hands.hlsli"
#include "clock.hlsli"

float4 mainImage(float2 fragCoord) {
    float3 f = framePoint(fragCoord, float3(1400.0, 690.0, 1260.0));
    float2 q = f.xy;
    float t = iTime;

    // Breathing in its sleep, once every 5.2 seconds: the dragon (outside the clock's rim, above the
    // slate) swells a little and rises, then settles.
    float breath = 0.5 - 0.5 * cos(t * 6.2831853 / 5.2);
    breath = breath * breath * (3.0 - 2.0 * breath);
    float r = length(q - kHub);
    float body = smoothstep(kDialR + 45.0, kDialR + 120.0, r) * smoothstep(1185.0, 1110.0, q.y);
    float2 qs = kHub + (q - kHub) / (1.0 + 0.009 * breath * body);
    qs.y += 3.5 * breath * body;
    float3 col = plate(qs);

    col = clockFace(q, col, iDate.w, float2(3.0, 4.0), 0.3);

    // The fireflies: each wanders slowly about where it was in the picture and glows brighter and
    // dimmer at its own pace. The same glow as in the picture: white-hot, yellow round the edge.
    [unroll] for (int k = 0; k < 4; k++) {
        float fk = (float)k;
        float2 wander = float2(sin(t * (0.23 + 0.04 * fk) + fk * 1.7) + 0.5 * sin(t * 0.61 + fk * 4.1),
                               cos(t * (0.19 + 0.05 * fk) + fk * 2.3) + 0.5 * sin(t * 0.47 + fk * 0.9)) * 34.0;
        float glow = 0.35 + 0.65 * smoothstep(-0.3, 1.0, sin(t * (0.9 + 0.23 * fk) + fk * 2.0));
        float d = length(q - kFireflies[k] - wander);
        float g = min(1.0, 1.5 * exp(-d / 4.6)) * glow;
        col += saturate(g * float3(1.0, 0.97, 0.2) + g * g * g * float3(0.0, 0.05, 0.75));
    }
    return float4(col * f.z, 1.0);
}
