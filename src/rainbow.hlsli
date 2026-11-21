// The settings window's RGB rainbow mode, for pictures (builtin.hlsl) and particle effects
// (particles.hlsl); shader wallpapers get the same thing as _Rainbow in sources.cpp.
// rainbow = (hue angle in radians, wave across the screen in radians, on, 0), from the cbuffer.

float3 Rainbow(float3 c, float2 px) {
    if (rainbow.z == 0) return c;
    float a = rainbow.x + rainbow.y * px.x / iResolution.x;
    const float3 k = float3(0.57735, 0.57735, 0.57735);
    float ca = cos(a);
    float3 r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1 - ca);
    // Turning hues leaves greys and whites as they are, so those take on the rainbow's color too.
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float grey = hi > 0 ? 1 - (hi - lo) / hi : 1;
    float3 tint = (0.5 + 0.5 * cos(a + float3(0, 2.0944, 4.1888))) * dot(c, float3(0.2126, 0.7152, 0.0722)) * 2;
    return lerp(r, tint, grey * 0.65);
}
