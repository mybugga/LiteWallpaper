// Door: stone steps climbing through fog to an open door full of golden light. The light beyond the
// door flickers like a great fire, its rays shift and shimmer through the haze, fog rolls slowly
// down the steps and drifts around them, and dust glitters in the light.
// texture: assets/door.jpg
// texture1: assets/door_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);    // picture pixels the positions below use
static const float2 kLight = float2(1445.0, 240.0);  // the light pours out of the doorway here
static const float2 kTop = float2(1440.0, 395.0);    // the steps run from the door...
static const float2 kBottom = float2(1180.0, 900.0); // ...down to here

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = fog (flows), g = the bright doorway (flickers), b = solid stone and the door.
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).r; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 fx = parts(q);
    // The fog drifts down and away from the steps.
    float3 col = fx.r > 0.001 ? streamSmoke(q, t, float2(-8.0, 5.0)) : picture(q);

    // The light beyond the door flickers like a great fire.
    float flick = 1.0 + 0.16 * (noise(float2(t * 2.3, 1.0)) - 0.5) + 0.08 * (noise(float2(t * 7.0, 4.0)) - 0.5) + 0.05 * sin(t * 0.7);
    float2 dl = q - kLight;
    float dist = length(dl);
    float warm = saturate((col.r - col.b) * 3.0) * smoothstep(0.05, 0.3, max(col.r, max(col.g, col.b)));
    col += col * fx.g * (flick - 1.0) * 1.8;
    col += col * warm * exp(-dist / 520.0) * (flick - 1.0) * 1.2;  // everything it lights flickers with it

    // Its rays shift and shimmer through the haze, fanning out from the doorway.
    float ang = atan2(dl.y, dl.x);
    // (broad soft shafts that drift slowly, faded in away from the doorway so they don't meet in a point)
    float rays = noise(float2(ang * 11.0, t * 0.22)) * 0.65 + noise(float2(ang * 4.5 - t * 0.09, 3.0)) * 0.35;
    float haze = smoothstep(0.03, 0.35, dot(col, float3(0.3, 0.5, 0.2))) * (1.0 - fx.b * 0.8) * (1.0 - fx.g);
    float leftward = smoothstep(-0.2, 0.4, -dl.x / max(dist, 1.0));
    float shafts = smoothstep(70.0, 220.0, dist) * exp(-dist / 520.0);
    col += col * haze * leftward * shafts * (rays - 0.45) * 1.6 * flick;

    // Fog rolling slowly down the steps, lit warm near the door.
    float2 sd = kBottom - kTop;
    float s = saturate(dot(q - kTop, sd) / dot(sd, sd));
    float fromStairs = length(q - kTop - sd * s);
    float band = smoothstep(260.0, 120.0, fromStairs) * smoothstep(-0.05, 0.08, s);
    if (band > 0.01) {
        float d = smokeDensity(q, t, float2(-12.0, 16.0), 130.0) * band;
        float3 tint = lerp(float3(0.13, 0.12, 0.11), float3(0.3, 0.2, 0.1), exp(-dist / 350.0) * flick);
        col += tint * d * 0.9;
    }

    // Dust glittering in the light.
    float inLight = leftward * exp(-dist / 380.0) * (1.0 - fx.b) * smoothstep(0.02, 0.15, dot(col, float3(0.3, 0.5, 0.2)));
    if (inLight > 0.01) {
        float dust = motes(p, t, 0.045, 0.0012, 0.4, 5.0, px) + motes(p, t, 0.08, 0.0025, 0.3, 13.0, px) * 0.7;
        col += float3(1.0, 0.82, 0.55) * dust * inLight * 0.9;
    }
    return float4(col, 1.0);
}
