// Plasma: smooth, dark, slowly morphing color fields.

float4 mainImage(float2 fragCoord) {
    float2 p = (fragCoord - 0.5 * iResolution) / iResolution.y * 3.0;
    float t = iTime * 0.15;

    float v = sin(p.x + t)
            + sin(p.y * 1.3 - t * 1.1)
            + sin((p.x + p.y) * 0.7 + t * 0.7)
            + sin(length(p + float2(sin(t * 0.5), cos(t * 0.4))) * 2.0);
    v *= 0.25;

    float3 col = 0.5 + 0.5 * cos(6.2831 * (v * 0.6 + float3(0.0, 0.33, 0.67) + t * 0.05));
    col *= 0.35;  // keep it dark so icons stay readable
    return float4(col, 1.0);
}
