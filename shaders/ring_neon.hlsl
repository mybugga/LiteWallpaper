// Ring neon: a brushed-metal ring lit cyan and magenta on black. It slowly spins, so the coloured
// light travels round it, a bright glint runs round the brushed metal, and the neon glow breathes.
// texture: assets/ring_neon.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"

static const float2 kCenter = float2(1017.0, 1012.0);  // picture pixels
static const float kInner = 816.0, kOuter = 948.0;

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = ringPoint(fragCoord, kCenter, kOuter);
    float2 pr = polar(q, kCenter);

    // The ring spins once every 30 seconds.
    float spin = t * 0.21;
    float3 col = picture(kCenter + rot(q - kCenter, -spin));

    // On the metal (not the black around it): a bright glint runs round, faster than the spin, and
    // a fainter one follows on the far side.
    float metal = smoothstep(kInner - 30.0, kInner + 6.0, pr.y) * smoothstep(kOuter + 30.0, kOuter - 6.0, pr.y);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float glint = nearAngle(pr.x, t * 1.05, 0.16) + 0.45 * nearAngle(pr.x, t * 1.05 + 3.14159, 0.22);
    // Brushed metal: the glint shimmers along fine circular streaks.
    float brushed = 0.65 + 0.35 * noise(float2(pr.y / 2.2, pr.x * 2.0));
    col += (col * 1.6 + 0.12) * glint * metal * brushed * smoothstep(0.05, 0.4, lum);

    // The coloured glow breathes.
    float sat = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));
    col *= 1.0 + 0.12 * sin(t * 0.8) * smoothstep(0.1, 0.5, sat);
    return float4(col, 1.0);
}
