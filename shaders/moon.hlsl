// Moon: the moon close up against black space, its edge lit blue-white. It slowly rocks on its
// axis the way the real moon does as seen from Earth (libration), so its craters and seas drift
// across its face while the sunlight on it, bright edge and all, stays where it is; the light
// along that edge glows softly and breathes.
// texture: assets/moon.jpg
// texture1: assets/moon_fx.png
// texture_portrait: assets/moon_portrait.jpg
// texture1_portrait: assets/moon_portrait_fx.png
// scale: 1
// focus: 0.8
// focus_portrait: 0.6
#include "space.hlsli"

#ifdef PORTRAIT
static const float2 kImg = float2(1440.0, 2560.0);
static const float2 kCenter = float2(1385.0, 2709.0);  // picture pixels: the moon's disc
static const float kRadius = 1534.0;
#else
static const float2 kImg = float2(2560.0, 1440.0);
static const float2 kCenter = float2(2432.0, 913.0);
static const float kRadius = 955.0;
#endif

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// The light on the moon (the picture blurred); the picture over it is the surface's own detail.
float3 light(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float3 surface(float2 q) { return (picture(q) + 0.015) / (light(q) + 0.015); }

// Turns a point of the visible face by the moon's rocking (small angles about the screen's upright
// and level axes) and returns the picture point that turns into it.
float2 rocked(float2 q, float a, float b) {
    float2 n = (q - kCenter) / kRadius;
    float z = sqrt(saturate(1.0 - dot(n, n)));
    float3 v = float3(n, z);
    float ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b);
    v = float3(ca * v.x - sa * v.z, v.y, sa * v.x + ca * v.z);
    v = float3(v.x, cb * v.y - sb * v.z, sb * v.y + cb * v.z);
    if (v.z < 0.0) v = float3(normalize(v.xy), 0.0);  // round from the far side: the nearest edge
    return kCenter + v.xy * kRadius;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float r = length(q - kCenter) / kRadius;
    float3 lit = light(q);
    float3 col = picture(q);

    if (r < 1.0) {
        // Libration: up to about 110 picture pixels of drift at the middle of the face, on two
        // slow, unequal cycles. The turn never reaches past the picture's edge.
        float k = 105.0 / kRadius;
        float a = k * (sin(t * 0.21) + 0.35 * sin(t * 0.083 + 2.0));
        float b = k * (0.65 * sin(t * 0.16 + 1.0) + 0.25 * sin(t * 0.061));
        float2 d = rocked(q, a, b) - q;
        // Near the limb the surface turns edge-on and hardly moves; keeping it still there keeps
        // the sharp sunlit edge whole.
        d *= 1.0 - smoothstep(0.88, 0.985, r);
        float2 edge = min(q, kImg - q);
        d *= saturate((min(edge.x, edge.y) - 8.0) / max(3.0 * length(d), 0.001));
        col = lit * surface(q + d);
    }

    // The sunlit edge glows softly past the limb, and breathes; from the light (not the sharp
    // picture), so it's even along the edge.
    float2 dirOut = normalize(q - kCenter);
    float3 rim = light(kCenter + dirOut * kRadius * 0.995);
    float rimLight = smoothstep(0.12, 0.45, dot(rim, float3(0.3, 0.4, 0.3)));
    float breath = 0.85 + 0.15 * sin(t * 0.5) + 0.05 * sin(t * 1.7);
    float outside = max(r - 1.0, 0.0) * kRadius;
    col += rim * rimLight * (exp(-outside / 14.0) * 0.35 + exp(-outside / 60.0) * 0.12) * breath * smoothstep(0.998, 1.004, r);
    return float4(col, 1.0);
}
