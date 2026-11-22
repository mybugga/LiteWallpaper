// Shared by the ring_* wallpapers: a square picture of a ring on black, shown whole and centred on
// any screen (wide or tall), the ring filling most of the screen's shorter side. Not a wallpaper
// itself (.hlsli files aren't listed).
#include "space.hlsli"

static const float2 kImg = float2(2048.0, 2048.0);

// The picture point under fragCoord: the ring (radius `outer` about `center`, picture pixels) is
// 86% of the screen's shorter side.
float2 ringPoint(float2 fragCoord, float2 center, float outer) {
    float2 d = fragCoord - iResolution * 0.5;  // screen pixels from the middle, y up
    float scale = outer / (0.43 * min(iResolution.x, iResolution.y));
    return center + float2(d.x, -d.y) * scale;
}

// The whole square picture, centred, `fill` of the screen's shorter side across (for pictures of a
// subject cut out on black).
float2 squarePoint(float2 fragCoord, float fill) { return ringPoint(fragCoord, kImg * 0.5, kImg.x * 0.43 / fill); }

// The picture, black beyond its edges.
float3 picture(float2 q) {
    float2 uv = q / kImg;
    float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
    return iChannel0.SampleLevel(iSampler, uv, 0).rgb * inside;
}

// Where round the ring a point is (radians) and how far from the middle (picture pixels).
float2 polar(float2 q, float2 center) {
    float2 d = q - center;
    return float2(atan2(d.y, d.x), length(d));
}

// How close an angle is to `at` (1 there, falling off over `width` radians either side).
float nearAngle(float a, float at, float width) {
    float d = abs(frac((a - at) / 6.2831853 + 0.5) - 0.5) * 6.2831853;
    return exp(-d * d / (width * width));
}
