// Dragon: a black dragon veined with fire. The molten cracks glow and flow, its eye burns brighter
// and dimmer, its throat glows, smoke streams from its jaws, smoke rolls around its feet, embers
// rise around it, and it breathes slowly while its wings flex.
// texture: assets/dragon.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);    // picture pixels the positions below use
static const float2 kEye = float2(1160.0, 290.0);
static const float2 kMouth = float2(1235.0, 470.0);  // where the smoke leaves the jaws
static const float2 kChest = float2(880.0, 941.0);   // it breathes about here
static const float2 kWingL = float2(430.0, 620.0);   // where each wing flexes from
static const float2 kWingR = float2(1300.0, 660.0);

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// Where the picture has smoke: at the jaws, and low around the feet.
float jawSmoke(float2 q) {
    float2 dm = q - kMouth;
    return smoothstep(0.0, 40.0, dm.x) * smoothstep(380.0, 250.0, dm.x) * smoothstep(170.0, 80.0, abs(dm.y + 40.0));
}
float smokeMask(float2 q) { return saturate(jawSmoke(q) + smoothstep(780.0, 880.0, q.y) * 0.6); }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // Breathing: a slow swell about the chest. Wings flex a little, out of step with the breath.
    float breath = 0.5 + 0.5 * sin(t * 0.8);
    float2 qs = kChest + (q - kChest) / (1.0 + 0.005 * breath);
    float flex = radians(0.9 * sin(t * 0.8 + 1.2));
    float wl = smoothstep(520.0, 420.0, q.x);
    float wr = smoothstep(1330.0, 1430.0, q.x);
    qs += (kWingL + rot(qs - kWingL, flex) - qs) * wl;
    qs += (kWingR + rot(qs - kWingR, -flex) - qs) * wr;

    // The smoke at its jaws streams away and rises; the smoke around its feet rolls sideways.
    float2 dm = q - kMouth;
    float3 col = streamSmoke(qs, t, jawSmoke(q) > 0.01 ? float2(22.0, -9.0) : float2(12.0, -3.0));
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // Molten cracks: fire flows through them and they pulse with the breath.
    float lava = saturate((col.r - max(col.g, col.b) - 0.12) * 3.0) * smoothstep(0.1, 0.4, col.r);
    float flow = fbm3(qs / 55.0 + float2(t * 0.05, -t * 0.12));
    col += col * lava * (0.7 * (flow - 0.35) + 0.35 * breath);
    col += float3(1.0, 0.45, 0.1) * lava * smoothstep(0.6, 0.85, flow) * 0.25;  // white-hot spots

    // The eye burns and the throat glows.
    float re = length(q - kEye) / kImg.y;
    col += float3(1.0, 0.15, 0.05) * (exp(-re / 0.008) * 0.5 + exp(-re / 0.03) * 0.12) * (0.55 + 0.45 * sin(t * 1.3));
    float rt = length((q - float2(1205.0, 480.0)) * float2(1.0, 1.6)) / kImg.y;
    col += float3(1.0, 0.3, 0.05) * exp(-rt / 0.03) * 0.12 * (0.6 + 0.4 * breath);

    // Smoke streaming from the jaws, thickest as it breathes out.
    float along = dm.x;
    if (along > -10.0 && along < 420.0) {
        float spread = 12.0 + along * 0.35;
        float centre = -along * 0.28 - 0.0004 * along * along;  // rises as it drifts away
        float plume = exp(-pow((dm.y - centre) / spread, 2.0)) * smoothstep(-10.0, 30.0, along) * exp(-along / 260.0);
        float puffs = fbm3(float2(along / 45.0 - t * 0.9, dm.y / 40.0 + t * 0.1));
        col += float3(0.5, 0.47, 0.47) * plume * smoothstep(0.35, 0.8, puffs) * (0.3 + 0.4 * breath);
    }

    // More smoke rolling low around its feet, lit by the fire.
    float low = smoothstep(700.0, 900.0, q.y);
    if (low > 0.01) {
        float d = smokeDensity(q, t, float2(16.0, -5.0), 220.0) * low;
        col += float3(0.2, 0.08, 0.06) * d * 0.8;  // dark smoke, lit red by the fire
    }

    // Embers rising from the fire below.
    col += embers(p, t, 0.08, 0.05, 0.0012, 0.3, 3.0, px, float3(1.0, 0.35, 0.08));
    col += embers(p, t, 0.15, 0.09, 0.002, 0.22, 9.0, px, float3(1.0, 0.45, 0.12)) * 0.8;
    return float4(col, 1.0);
}
