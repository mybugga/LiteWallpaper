// Prism: a glass prism hanging on a cord splits a white beam into a rainbow. It sways gently on its
// cord and the rainbow swings with it (refraction magnifies the turn), pulses of light run along the
// white beam into the glass and stream out through the colours, dust drifts glinting in the light,
// the prism's edges sparkle, and the rainbow's reflection on the table moves with it.
// texture: assets/prism.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kPivot = float2(1275.0, -200.0);  // the cord's hook, above the picture
static const float2 kApex = float2(1275.0, 207.0);    // the prism's corners
static const float2 kLeft = float2(1033.0, 642.0);
static const float2 kRight = float2(1488.0, 598.0);
static const float2 kBeamFrom = float2(650.0, 545.0); // the white beam, from the left...
static const float2 kBeamIn = float2(1135.0, 452.0);  // ...into the prism
static const float2 kExit = float2(1410.0, 440.0);    // the rainbow leaves the far face here

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// Signed distance from the line a->b; positive on the right of a->b (picture y points down).
float edgeSide(float2 q, float2 a, float2 b) {
    float2 d = normalize(b - a);
    return (q.x - a.x) * d.y - (q.y - a.y) * d.x;
}
// How far inside the prism q is (negative outside), in pixels.
float insidePrism(float2 q) {
    return min(min(-edgeSide(q, kApex, kLeft), -edgeSide(q, kLeft, kRight)), -edgeSide(q, kRight, kApex));
}

float swing(float t) { return 0.0105 * sin(t * 0.7) + 0.003 * sin(t * 1.9 + 1.0); }  // radians

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float a = swing(t);
    float2 qs = q;

    // The prism, its ring and cord sway as one about the hook.
    float2 qp = kPivot + rot(q - kPivot, -a);
    float onPrism = smoothstep(-14.0, -4.0, insidePrism(qp));
    float onCord = smoothstep(9.0, 4.0, abs(qp.x - kApex.x)) * step(qp.y, kApex.y + 4.0);
    float prismW = max(onPrism, onCord);
    qs = lerp(qs, qp, prismW);

    // Beyond the far face the rainbow swings about where it leaves the glass, three times as far.
    // Only the rainbow's own fan turns (not the glass edge below it), starting a little beyond the
    // face as it is now.
    float2 exitNow = kPivot + rot(kExit - kPivot, a);
    float fanAngle = atan2(q.y - exitNow.y, q.x - exitNow.x);
    float inFanAngle = smoothstep(-0.62, -0.47, fanAngle) * smoothstep(0.36, 0.22, fanAngle);
    float outside = smoothstep(10.0, 24.0, edgeSide(qp, kApex, kRight)) * step(kExit.x - 60.0, q.x) * (1.0 - prismW) * inFanAngle;
    if (outside > 0.0) qs = lerp(qs, kExit + rot(q - exitNow, -3.0 * a), outside);
    // Its reflection on the table moves too.
    float table = smoothstep(640.0, 680.0, q.y) * smoothstep(1050.0, 1150.0, q.x);
    qs.x -= 3.0 * a * 900.0 * table * 0.35;

    float3 col = picture(qs);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float sat = (max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b))) / max(max(col.r, max(col.g, col.b)), 0.02);

    // Light streams out through the rainbow in pulses.
    float2 fromExit = q - exitNow;
    float dist = length(fromExit);
    float fan = smoothstep(0.25, 0.6, sat) * smoothstep(0.05, 0.25, lum) * outside;
    float wave = pow(0.5 + 0.5 * sin(dist / 34.0 - t * 4.2 + 2.0 * noise(float2(atan2(fromExit.y, fromExit.x) * 9.0, t * 0.2))), 6.0);
    col += col * fan * (0.75 * wave + 0.15 * sin(t * 1.3));

    // Pulses run along the white beam into the glass.
    float2 bd = normalize(kBeamIn - kBeamFrom);
    float bl = length(kBeamIn - kBeamFrom);
    float along = dot(q - kBeamFrom, bd);
    float perp = abs((q.x - kBeamFrom.x) * bd.y - (q.y - kBeamFrom.y) * bd.x);
    float beamCore = exp(-pow(perp / (2.0 + 4.0 * (1.0 - saturate(along / bl))), 2.0)) * smoothstep(-20.0, 60.0, along) * smoothstep(bl + 30.0, bl, along);
    float travel = pow(0.5 + 0.5 * sin(along / 26.0 - t * 6.0), 10.0);
    col += float3(1.0, 1.0, 1.0) * beamCore * (0.35 * travel + 0.06 * sin(t * 2.0 + along / 90.0));

    // Dust drifting through the beam and the rainbow, glinting in their light.
    float inBeam = exp(-pow(perp / (14.0 + 20.0 * (1.0 - saturate(along / bl))), 2.0)) * smoothstep(-20.0, 80.0, along) * step(along, bl);
    float inFan = fan + smoothstep(0.08, 0.3, lum) * outside * 0.5;
    float dust = motes(p, t, 0.05, 0.0013, 0.35, 3.0, px) + motes(p, t, 0.09, 0.0028, 0.25, 9.0, px) * 0.7;
    float3 tint = lerp(float3(1.0, 1.0, 1.0), col / max(lum, 0.05) * 0.5, saturate(inFan));
    col += tint * dust * saturate(inBeam + inFan) * 0.9;

    // The prism's edges sparkle.
    float2 glintAt = qs;
    float g = twinkle(glintAt, t * 0.8, 16.0, 80.0);
    col += float3(1.0, 1.0, 1.0) * g * smoothstep(0.55, 0.85, lum) * (1.0 - smoothstep(0.3, 0.6, sat)) * onPrism * 1.6;
    return float4(col, 1.0);
}
