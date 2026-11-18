// Astronaut, spiral galaxy: the astronaut faces the Whirlpool Galaxy, M51, and its small companion
// (NASA, ESA, S. Beckwith, Hubble Heritage Team), tinted toward the violet in the visor. The galaxy
// turns ever so slightly back and forth and stars drift past while the camera floats.
// texture: assets/astronaut_galaxy.png
// texture1: assets/space_galaxy.jpg
// scale: 1
#include "space.hlsli"

static const float2 kCoreUV = float2(0.388, 0.485);  // the galaxy's core in the photo
static const float2 kCoreAt = float2(0.80, 0.56);    // where it sits on screen
static const float kHeight = 1.15;

float3 sky(float2 p, float px, float t, float aspect) {
    float angle = -0.35 + 0.04 * sin(t * 0.005);
    float2 uv = backdropUV(p, kCoreAt, kCoreUV, kHeight, angle, t);
    float3 c = backdrop(uv);
    // Lean toward the visor's violet: blues go purple, the core stays gold.
    float3 col = float3(c.r * 1.02 + c.b * 0.18, c.g * 0.88, c.b * 1.12);
    col += starField(p, px, t, 0.0);
    col += shootingStar(p, aspect, t, px, float3(0.9, 0.85, 1.0));
    return col * vignette(p, aspect);
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float2 size;
    float4 photo = samplePhoto(p, aspect, t, size);
    float3 col = photo.a < 0.995 ? sky(p, px, t, aspect) : 0;
    col = col * (1.0 - photo.a) + photo.rgb;
    col += visorFlare(p, photoToScreen(kVisorUV, size, aspect), px, t, float3(0.75, 0.45, 1.0));
    col += suitLights(p, size, aspect, px, t);
    return float4(col, 1.0);
}
