// Gradient: four soft color blobs wandering slowly. The cheapest of the bundled shaders.

float4 mainImage(float2 fragCoord) {
    float2 uv = fragCoord / iResolution;
    uv.x *= iResolution.x / iResolution.y;
    float t = iTime * 0.05;

    float2 p0 = float2(0.4 + 0.3 * sin(t * 1.1), 0.3 + 0.2 * cos(t * 0.9));
    float2 p1 = float2(1.3 + 0.3 * cos(t * 0.7), 0.7 + 0.2 * sin(t * 1.3));
    float2 p2 = float2(0.9 + 0.4 * sin(t * 0.5 + 2.0), 0.5 + 0.3 * cos(t * 0.6 + 1.0));
    float2 p3 = float2(1.6 + 0.2 * sin(t * 0.8 + 4.0), 0.2 + 0.2 * cos(t * 1.0 + 3.0));

    float w0 = 1.0 / (0.05 + dot(uv - p0, uv - p0));
    float w1 = 1.0 / (0.05 + dot(uv - p1, uv - p1));
    float w2 = 1.0 / (0.05 + dot(uv - p2, uv - p2));
    float w3 = 1.0 / (0.05 + dot(uv - p3, uv - p3));

    float3 col = (float3(0.10, 0.20, 0.45) * w0 + float3(0.40, 0.12, 0.35) * w1 +
                  float3(0.05, 0.30, 0.32) * w2 + float3(0.30, 0.20, 0.08) * w3) / (w0 + w1 + w2 + w3);
    return float4(col, 1.0);
}
