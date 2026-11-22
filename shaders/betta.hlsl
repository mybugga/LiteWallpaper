// Betta: a red and blue fighting fish hanging in the dark water. Its long fins billow and ripple
// in slow waves that run out from its body to their tips, it sways gently as it breathes, its
// small chest fin flutters, its gills open and close, and light shimmers over its blue scales.
// texture: assets/betta.jpg
// texture1: assets/betta_fx.png
// texture_portrait: assets/betta_portrait.jpg
// texture1_portrait: assets/betta_portrait_fx.png
// scale: 1
// focus: 0.72
// focus_portrait: 0.3
#include "space.hlsli"

#ifdef PORTRAIT
static const float2 kImg = float2(1440.0, 2560.0);
static const float2 kEye = float2(212.0, 1252.0);     // picture pixels
static const float2 kGill = float2(330.0, 1355.0);
static const float2 kPecFin = float2(400.0, 1490.0);  // the small chest fin
static const float2 kTailBase = float2(760.0, 1690.0);
#else
static const float2 kImg = float2(2560.0, 1440.0);
static const float2 kEye = float2(1190.0, 654.0);
static const float2 kGill = float2(1330.0, 670.0);
static const float2 kPecFin = float2(1480.0, 700.0);
static const float2 kTailBase = float2(1890.0, 600.0);
#endif

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// fx: r = how far out along a fin (0 body - 1 tips), gb = the direction away from the body
float3 fins(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The whole fish sways a little and rises and falls as it breathes, about its middle.
    float2 mid = lerp(kEye, kTailBase, 0.55);
    float sway = sin(t * 0.55) * 0.012 + sin(t * 0.31 + 1.0) * 0.008;
    float2 qs = mid + rot(q - mid, -sway) - float2(0.0, sin(t * 0.7) * 6.0);

    // The fins: waves travel out from the body to the tips, growing as they go, so the fins billow
    // and ripple like silk in slow water. Each part of a fin waves a little out of step with its
    // neighbours (noise in the phase), and the tips lag and flutter most.
    float3 f = fins(qs);
    float along = f.r;
    float2 dir = normalize(f.gb * 2.0 - 1.0 + 1e-4);
    float2 across = float2(-dir.y, dir.x);
    float reach = 680.0 * along;                                   // pixels from the body
    float phase = reach / 210.0 - t * 1.25 + noise(qs / 260.0) * 2.4;
    float wave = sin(phase) + 0.35 * sin(phase * 2.3 + 1.7 + t * 0.4);
    float amp = smoothstep(0.0, 0.18, along) * (9.0 + 34.0 * along * along);
    float2 billow = across * wave * amp + dir * sin(phase * 0.5 - 0.6) * amp * 0.45;
    // Fine flutter at the ragged tips.
    float2 flutter = (float2(noise(qs / 22.0 + float2(t * 1.6, 0.0)), noise(qs / 22.0 + float2(3.0, t * 1.4))) - 0.5) * 9.0 * smoothstep(0.55, 1.0, along);
    float2 qf = qs - billow - flutter;

    // The small chest fin beats quickly to hold the fish in place.
    float rp = length(qs - kPecFin);
    float pec = smoothstep(150.0, 40.0, rp);
    qf += rot(qs - kPecFin, sin(t * 4.2) * 0.12) * pec - (qs - kPecFin) * pec;

    // The gills open and close as it breathes.
    float rg = length(qs - kGill);
    qf += (qs - kGill) * smoothstep(60.0, 10.0, rg) * (0.04 * sin(t * 1.9));

    float3 col = picture(qf);

    // Light shimmering over the blue scales: soft bands drifting along the body.
    float blue = saturate((col.b - col.r) * 3.0) * smoothstep(0.05, 0.25, col.b);
    float bands = pow(saturate(0.5 + 0.5 * sin(dot(qs, float2(0.018, 0.006)) - t * 1.7 + noise(qs / 90.0) * 3.0)), 6.0);
    col += float3(0.2, 0.55, 1.0) * bands * blue * 0.6;
    // Glints on the scales.
    col += float3(0.6, 0.85, 1.0) * twinkle(qs, t, 7.0, 28.0) * blue * 0.7;

    // The red fins glow a little brighter where a wave's crest faces the light.
    float red = saturate((col.r - col.b) * 2.0) * smoothstep(0.08, 0.3, col.r);
    col *= 1.0 + red * 0.16 * wave * smoothstep(0.1, 0.4, along);
    return float4(col, 1.0);
}
