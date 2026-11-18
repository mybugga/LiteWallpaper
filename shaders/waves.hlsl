// Waves: layered translucent ribbons drifting across a deep gradient.

float4 mainImage(float2 fragCoord) {
    float2 uv = fragCoord / iResolution;
    float t = iTime * 0.12;

    float3 col = lerp(float3(0.03, 0.02, 0.08), float3(0.10, 0.05, 0.20), uv.y);

    for (int i = 0; i < 5; i++) {
        float fi = (float)i;
        float freq = 2.0 + fi * 0.7;
        float y = 0.30 + fi * 0.09
                + sin(uv.x * freq + t * (1.0 + fi * 0.25) + fi * 1.7) * 0.06
                + sin(uv.x * freq * 2.3 - t * 0.8 + fi) * 0.02;
        float d = uv.y - y;
        float body = smoothstep(0.0, -0.25, d) * 0.10;          // fill below the line
        float edge = exp(-d * d * 4000.0) * 0.6;                // thin bright crest
        float3 tint = lerp(float3(0.95, 0.35, 0.55), float3(0.30, 0.55, 1.0), fi / 4.0);
        col = lerp(col, tint * 0.6, body);
        col += tint * edge;
    }
    return float4(col, 1.0);
}
