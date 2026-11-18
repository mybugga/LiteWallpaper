// Aurora: slow curtains of light over a starry night sky.
// Available: iResolution (pixels), iTime (seconds), iFrame. Write float4 mainImage(float2 fragCoord).

float hash(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float noise(float2 p) {
    float2 i = floor(p), f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash(i), hash(i + float2(1, 0)), u.x),
                lerp(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return v;
}

float4 mainImage(float2 fragCoord) {
    float2 uv = fragCoord / iResolution;
    float aspect = iResolution.x / iResolution.y;
    float x = uv.x * aspect;
    float t = iTime * 0.04;

    float3 col = lerp(float3(0.005, 0.01, 0.03), float3(0.02, 0.04, 0.10), uv.y);

    // Soft stars, twinkling slowly.
    float2 grid = float2(x, uv.y) * 90.0;
    float2 cell = floor(grid);
    float star = hash(cell);
    float2 off = float2(hash(cell + 3.1), hash(cell + 7.7)) - 0.5;
    float d = length(frac(grid) - 0.5 - off * 0.6);
    float twinkle = 0.6 + 0.4 * sin(iTime * (0.5 + star * 2.0) + star * 40.0);
    col += step(0.985, star) * smoothstep(0.18, 0.0, d) * twinkle * smoothstep(0.2, 0.9, uv.y) * 0.8;

    // Three curtains.
    for (int i = 0; i < 3; i++) {
        float fi = (float)i;
        float drift = fbm(float2(x * 0.9 + fi * 4.3 + t * (1.0 + fi * 0.4), t * 0.6 + fi * 2.0));
        float center = 0.52 + fi * 0.09 + (drift - 0.5) * 0.45;
        float dy = uv.y - center;
        float rays = 0.55 + 0.45 * fbm(float2(x * 7.0 + fi * 13.0 - t * 3.0, fi * 5.0 + t));
        // Sharp lower edge, long fade upward, like real aurora.
        float band = dy < 0.0 ? exp(-dy * dy * 900.0) : exp(-dy * 7.0) * exp(-dy * dy * 20.0);
        float3 tint = lerp(float3(0.10, 0.95, 0.55), float3(0.45, 0.30, 0.95), saturate(dy * 3.0 + fi * 0.3));
        col += tint * band * rays * (0.45 - fi * 0.08);
    }

    // Faint glow on the horizon.
    col += float3(0.02, 0.08, 0.07) * exp(-uv.y * 6.0);
    return float4(col, 1.0);
}
