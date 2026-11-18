// Fox mask: a white kitsune mask hanging on red cords in drifting smoke. It sways gently on its cords
// with its knots and bells, the tassels swing after it, the long ribbons ripple and flutter in the
// air, the bells glint as they swing, and the smoke curls up around it.
// texture: assets/foxmask.jpg
// texture1: assets/foxmask_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);      // picture pixels the positions below use
static const float2 kHook = float2(1390.0, -600.0);    // the cords hang from far above
static const float2 kTasselL = float2(1150.0, 505.0);  // where each tassel hangs from
static const float2 kTasselR = float2(1545.0, 495.0);
static const float2 kBellL = float2(1148.0, 488.0);
static const float2 kBellR = float2(1545.0, 478.0);

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = everything hanging from the cords (sways), g = smoke, b = ribbons (flutter).
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).g; }
#include "fx.hlsli"

float swayAngle(float t) { return radians(0.55 * sin(t * 0.62) + 0.18 * sin(t * 1.45 + 1.0)); }

// How much of a tassel is at q (they hang below their knots), and its swing about its top.
float tassel(float2 q, float2 top, float halfWidth, float len) {
    float2 d = q - top;
    return smoothstep(-4.0, 6.0, d.y) * smoothstep(len, len - 10.0, d.y) * smoothstep(halfWidth, halfWidth - 8.0, abs(d.x));
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The mask and all that hangs from it sway about the hook far above.
    float a = swayAngle(t);
    float w = parts(q).r;
    float2 qs = lerp(q, kHook + rot(q - kHook, -a), w);

    // The tassels swing after it, a little behind and further.
    float aT = radians(2.6 * sin(t * 0.62 - 0.9) + 0.8 * sin(t * 1.7 + 0.4));
    float tl = tassel(qs, kTasselL, 40.0, 200.0) * w;
    float tr = tassel(qs, kTasselR, 56.0, 268.0) * w;
    qs = lerp(qs, kTasselL + rot(qs - kTasselL, -aT), tl);
    qs = lerp(qs, kTasselR + rot(qs - kTasselR, -aT * 0.85), tr);
    // Their strands stir.
    qs.x += (noise(float2(qs.x / 4.0, qs.y / 30.0 - t * 1.4)) - 0.5) * 2.0 * max(tl, tr) * smoothstep(0.0, 120.0, qs.y - 560.0);

    // The ribbons ripple: waves run out along them, bigger toward their ends.
    float rib = parts(qs).b;
    if (rib > 0.001) {
        float2 wv = qs / 34.0 + float2(t * 0.9, -t * 0.5);
        qs += (float2(noise(wv), noise(wv + 4.7)) - 0.5) * 14.0 * rib + float2(0.0, sin(qs.x / 40.0 + t * 2.3) * 6.0 * rib);
    }

    // Smoke flows in the open; near the mask the air (and any smoke in it) moves with the mask.
    float hold = smoothstep(0.25, 0.75, w);
    float3 col = picture(qs);
    if (hold < 1.0) {
        float3 smoke = streamSmoke(q, t, float2(5.0, -15.0));
        smoke += smoke * smokeWisps(q, t) * parts(q).g * 0.5;
        col = lerp(smoke, col, hold);
    }

    // More smoke curling up from below and drifting through.
    float low = smoothstep(560.0, 760.0, q.y) * smoothstep(900.0, 1050.0, q.x) * (1.0 - w);
    float side = smoothstep(1550.0, 1640.0, q.x) * (1.0 - w);
    float more = max(low, side * 0.7);
    if (more > 0.01) {
        float d = smokeDensity(q, t, float2(6.0, -18.0), 160.0) * more;
        col += float3(0.15, 0.15, 0.16) * d;
    }

    // The bells glint as they swing.
    [unroll] for (int i = 0; i < 2; i++) {
        float2 bell = i == 0 ? kBellL : kBellR;
        float2 at = kHook + rot(bell - kHook, a) + float2(-4.0, -5.0);
        float flash = pow(saturate(sin(t * 0.62 * 2.0 + i * 1.7)), 12.0);
        float2 d = q - at;
        float star = exp(-length(d) / 2.5) * 0.8 + (exp(-abs(d.y) / 0.8) * exp(-abs(d.x) / 14.0) + exp(-abs(d.x) / 0.8) * exp(-abs(d.y) / 14.0)) * 0.6;
        col += float3(1.0, 0.85, 0.5) * star * flash;
    }
    return float4(col, 1.0);
}
