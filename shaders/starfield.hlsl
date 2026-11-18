// Starfield: three layers of stars drifting at different speeds, with a faint nebula.

float hash(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float layer(float2 p, float density) {
    float2 cell = floor(p);
    float2 f = frac(p) - 0.5;
    float h = hash(cell);
    float2 off = float2(hash(cell + 1.3), hash(cell + 8.1)) - 0.5;
    float d = length(f - off * 0.7);
    return step(1.0 - density, h) * smoothstep(0.12, 0.0, d) * (0.5 + 0.5 * hash(cell + 4.2));
}

float4 mainImage(float2 fragCoord) {
    float2 uv = fragCoord / iResolution.y;
    float t = iTime;

    float3 col = float3(0.004, 0.006, 0.015);
    float2 n = uv * 1.5 + float2(t * 0.003, 0.0);
    col += float3(0.05, 0.02, 0.08) * (0.5 + 0.5 * sin(n.x * 2.0 + sin(n.y * 3.0)));
    col += float3(0.01, 0.04, 0.06) * (0.5 + 0.5 * sin(n.y * 2.5 - n.x * 1.5 + 1.0));

    col += layer(uv * 30.0 + float2(t * 0.02, 0.0), 0.06) * 0.5;
    col += layer(uv * 18.0 + float2(t * 0.05, 3.0), 0.05) * 0.8;
    col += layer(uv * 10.0 + float2(t * 0.10, 7.0), 0.04) * float3(1.0, 0.95, 0.85);
    return float4(col, 1.0);
}
