// Ring gold: an art-deco ring of brushed gold, its grooved bands joined by chevrons. Light runs
// round it, a sheen sliding along the grooves and flashing across the chevrons as it passes, with
// glints on the raised edges, and the gold's warm glow slowly swells and fades.
// texture: assets/ring_gold.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"

static const float2 kCenter = float2(1012.0, 1010.0);  // picture pixels
static const float kInner = 801.0, kOuter = 940.0;

float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = ringPoint(fragCoord, kCenter, kOuter);
    float2 pr = polar(q, kCenter);
    float3 col = picture(q);

    float gold = smoothstep(kInner - 20.0, kInner + 4.0, pr.y) * smoothstep(kOuter + 20.0, kOuter - 4.0, pr.y);
    float lum = dot(col, float3(0.3, 0.55, 0.15));

    // The sheen: a band of light sliding round, once every 9 seconds, with a softer one behind.
    float at = t * 0.7;
    float sheen = nearAngle(pr.x, at, 0.2) + 0.35 * nearAngle(pr.x, at - 1.2, 0.45);
    // The raised parts of the grooves catch it most.
    float raised = smoothstep(0.25, 0.7, lum);
    col += col * float3(1.1, 0.95, 0.7) * sheen * gold * (0.25 + 1.1 * raised);

    // Glints on the raised edges, brightest in the sheen.
    col += float3(1.0, 0.85, 0.55) * twinkle(q, t, 9.0, 30.0) * raised * gold * (0.25 + sheen) * 0.8;

    // The warm glow swells and fades.
    col *= 1.0 + 0.08 * sin(t * 0.45) * gold;
    return float4(col, 1.0);
}
