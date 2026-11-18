// particles.js rendering: one instanced quad per particle / line, shapes drawn as anti-aliased
// distance fields. Output is premultiplied alpha. Precompiled by build.bat.

cbuffer Globals : register(b0) {
    float2 iResolution;
    float iTime;
    float iFrame;
    float4 uvXform;
    float4 extra;  // x = background repeat
};

Texture2D tex0 : register(t0);
SamplerState smp0 : register(s0);

float2 ToClip(float2 px) { return float2(px.x / iResolution.x * 2 - 1, 1 - px.y / iResolution.y * 2); }

// ---------------------------------------------------------------------------------------------
// Particles

struct PartIn {
    float2 center : TEXCOORD0;
    float2 half : TEXCOORD1;
    float4 fill : TEXCOORD2;    // straight alpha
    float4 stroke : TEXCOORD3;  // rgb + width
    float4 shape : TEXCOORD4;   // type, R, Rin, sides
    float4 param : TEXCOORD5;   // rotation, image flag
    uint vid : SV_VertexID;
};

struct PartOut {
    float4 pos : SV_Position;
    float2 local : TEXCOORD0;  // pixels from the particle center, y down
    float2 uv : TEXCOORD1;
    nointerpolation float4 fill : TEXCOORD2;
    nointerpolation float4 stroke : TEXCOORD3;
    nointerpolation float4 shape : TEXCOORD4;
    nointerpolation float4 param : TEXCOORD5;
};

PartOut VSParticle(PartIn i) {
    float2 corner = float2((i.vid & 1) ? 1 : -1, (i.vid & 2) ? 1 : -1);
    PartOut o;
    o.local = corner * i.half;
    o.uv = corner * 0.5 + 0.5;
    o.pos = float4(ToClip(i.center + o.local), 0, 1);
    o.fill = i.fill;
    o.stroke = i.stroke;
    o.shape = i.shape;
    o.param = i.param;
    return o;
}

// Regular polygon / star with tips at radius R and inner corners at Rin; a tip points up.
float SdStarPoly(float2 p, float R, float Rin, float n, float rot) {
    float an = 3.14159265 / n;
    float a = atan2(p.x, p.y) + rot;
    float b = a - 2 * an * floor((a + an) / (2 * an));
    float2 q = length(p) * float2(abs(sin(b)), cos(b));
    float2 T = float2(0, R);
    float2 I = float2(Rin * sin(an), Rin * cos(an));
    float2 e = I - T;
    float2 w = q - T;
    float h = saturate(dot(w, e) / dot(e, e));
    float d = length(w - e * h);
    return (e.x * w.y - e.y * w.x) < 0 ? -d : d;
}

float4 PSParticle(PartOut i) : SV_Target {
    if (i.param.y > 0.5) return tex0.SampleLevel(smp0, i.uv, 0);  // image particle, drawn as-is

    float2 p = i.local;
    float type = i.shape.x, R = i.shape.y;
    float d;
    if (type < 0.5) {
        d = length(p) - R;  // circle
    } else if (type < 1.5) {
        float2 q = abs(p) - R;  // "edge" = square
        d = length(max(q, 0)) + min(max(q.x, q.y), 0);
    } else {
        d = SdStarPoly(float2(p.x, -p.y), R, i.shape.z, i.shape.w, i.param.x);
    }

    // Canvas strokes first, then fills on top: the outer half of the stroke shows fully, the
    // inner half shows through the (possibly translucent) fill.
    float fillCov = saturate(0.5 - d) * i.fill.a;
    float sw = i.stroke.w;
    float strokeCov = sw > 0 ? saturate(0.5 - (d - sw * 0.5)) - saturate(0.5 - (d + sw * 0.5)) : 0;
    float3 rgb = i.fill.rgb * fillCov + i.stroke.rgb * strokeCov * (1 - fillCov);
    float a = fillCov + strokeCov * (1 - fillCov);
    return float4(rgb, a);
}

// ---------------------------------------------------------------------------------------------
// Lines

struct LineIn {
    float4 ends : TEXCOORD0;   // x0 y0 x1 y1
    float4 color : TEXCOORD1;  // straight alpha
    float width : TEXCOORD2;
    uint vid : SV_VertexID;
};

struct LineOut {
    float4 pos : SV_Position;
    float across : TEXCOORD0;
    nointerpolation float width : TEXCOORD1;
    nointerpolation float4 color : TEXCOORD2;
};

LineOut VSLine(LineIn i) {
    float2 a = i.ends.xy, b = i.ends.zw;
    float2 dir = b - a;
    float len = length(dir);
    dir = len > 1e-4 ? dir / len : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float side = (i.vid & 2) ? 1 : -1;
    float extent = i.width * 0.5 + 1;
    float2 px = ((i.vid & 1) ? b : a) + nrm * side * extent;
    LineOut o;
    o.pos = float4(ToClip(px), 0, 1);
    o.across = side * extent;
    o.width = i.width;
    o.color = i.color;
    return o;
}

float4 PSLine(LineOut i) : SV_Target {
    float cov = saturate(i.width * 0.5 + 0.5 - abs(i.across));
    float a = i.color.a * cov;
    return float4(i.color.rgb * a, a);
}

// ---------------------------------------------------------------------------------------------
// Background image (CSS background-size / background-position), uses VSMain from builtin.hlsl

float4 PSBackground(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    float2 t = uv * uvXform.xy + uvXform.zw;
    float inside = extra.x > 0.5 ? 1 : step(0, t.x) * step(t.x, 1) * step(0, t.y) * step(t.y, 1);
    return tex0.Sample(smp0, t) * inside;
}
