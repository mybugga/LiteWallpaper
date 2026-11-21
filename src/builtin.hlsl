// Precompiled at build time with fxc (see build.bat), so video/image wallpapers never load the shader compiler.

cbuffer Globals : register(b0) {
    float2 iResolution;
    float iTime;
    float iFrame;
    float4 uvXform;  // xy = scale, zw = offset
    float4 extra;
    float4 rainbow;
};
#include "rainbow.hlsli"

Texture2D tex0 : register(t0);
SamplerState smp0 : register(s0);

struct VSOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// One triangle that covers the whole screen; no vertex buffer needed.
VSOut VSMain(uint id : SV_VertexID) {
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

float4 PSTex(VSOut i) : SV_Target {
    float2 t = i.uv * uvXform.xy + uvXform.zw;
    float3 c = Rainbow(tex0.Sample(smp0, t).rgb, i.pos.xy);
    float inside = step(0, t.x) * step(t.x, 1) * step(0, t.y) * step(t.y, 1);  // letterbox bars
    return float4(c * inside, 1);
}
