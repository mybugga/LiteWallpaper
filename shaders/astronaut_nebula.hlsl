// Astronaut, emerald nebula: the astronaut faces the Pillars of Creation in the Eagle Nebula
// (NASA, ESA, Hubble Heritage Team, 2014), tinted toward the emerald in the visor. The gas glows
// and dims slowly in places, and stars drift past while the camera floats.
// texture: assets/astronaut_nebula.png
// texture1: assets/space_nebula.jpg
// scale: 1
#include "space.hlsli"

static const float2 kAt = float2(0.84, 0.50);  // where the middle of the photo sits on screen
static const float kHeight = 1.2;

float3 sky(float2 p, float px, float t, float aspect) {
    float2 uv = backdropUV(p, kAt, float2(0.5, 0.5), kHeight, -0.05, t);
    float3 c = backdrop(uv);
    // Shift the photo's blue-teal gas toward emerald and keep the pillars a warm bronze.
    float3 col = float3(c.r * 0.92, c.g * 0.72 + c.b * 0.45, c.g * 0.25 + c.b * 0.55);
    // Slow glowing and dimming across the gas.
    col *= 1.0 + 0.18 * (fbm3(uv * 4.0 + float2(t * 0.015, -t * 0.011)) - 0.5);

    col += starField(p, px, t, 0.0);
    col += shootingStar(p, aspect, t, px, float3(0.8, 1.0, 0.9));
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
    col += visorFlare(p, photoToScreen(kVisorUV, size, aspect), px, t, float3(0.35, 1.0, 0.6));
    col += suitLights(p, size, aspect, px, t);
    return float4(col, 1.0);
}
