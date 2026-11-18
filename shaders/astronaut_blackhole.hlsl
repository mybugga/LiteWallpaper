// Astronaut, black hole: the astronaut faces a black hole, from NASA's visualization of one (NASA
// Goddard / Jeremy Schnittman, SVS 14619). The gas in its disk keeps flowing round, the light
// around it shimmers, and nearby stars drift past while the camera floats.
// texture: assets/astronaut_blackhole.png
// texture1: assets/space_blackhole.jpg
// scale: 1
#include "space.hlsli"

static const float2 kHole = float2(0.86, 0.56);  // where the shadow sits, screen-height units
static const float kHeight = 1.25;               // backdrop height, in screen heights
static const float kShadowR = 0.0376 / 0.5625;   // shadow radius in backdrop uv heights (measured)

float3 sky(float2 p, float px, float t, float aspect) {
    float2 uv = backdropUV(p, kHole, float2(0.5, 0.5), kHeight, -0.03, t);

    // Make the disk flow: twist the picture around the hole a little, more near the middle and in
    // waves that travel outward, so the gas appears to swirl and the light to shimmer.
    float tw, th;
    iChannel1.GetDimensions(tw, th);
    float2 v = (uv - 0.5) * float2(tw / th, 1.0);
    float r = length(float2(v.x, v.y * 3.0)) / kShadowR;  // in shadow radii, flattened like the disk
    float twist = 0.012 * exp(-r * 0.12) * sin(t * 0.9 - r * 0.8) + 0.004 * sin(t * 0.37 + r * 0.3);
    v = rot(v, twist);
    uv = v * float2(th / tw, 1.0) + 0.5;

    float3 col = backdrop(uv);
    // Brightness ripples running round the disk.
    float a = atan2(v.y * 3.0, v.x);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float flow = noise(float2(a * 3.0 - t * 0.6 + r * 0.15, r * 0.6 - t * 0.2));
    col *= 1.0 + 0.22 * (flow - 0.5) * smoothstep(0.15, 0.6, lum) * smoothstep(1.2, 2.0, r);

    // Grade toward the visor: teal in the dark gas, orange in the bright.
    lum = dot(col, float3(0.3, 0.5, 0.2));
    col *= lerp(float3(0.75, 1.0, 1.2), float3(1.15, 0.95, 0.78), smoothstep(0.03, 0.5, lum));

    col += starField(p, px, t, 0.0) * 0.7;
    col += shootingStar(p, aspect, t, px, float3(1.0, 0.92, 0.85));
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
    col += visorFlare(p, photoToScreen(kVisorUV, size, aspect), px, t, float3(1.0, 0.58, 0.22));
    col += suitLights(p, size, aspect, px, t);
    return float4(col, 1.0);
}
