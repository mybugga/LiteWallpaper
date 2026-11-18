// Car: a black supercar in the rain at night. Rain falls past the camera and splashes in the
// puddles, the reflections on the wet ground ripple, the grey and red smoke rolls away from the car
// with more drifting low along the ground, drops glint on the paint, and the taillights breathe
// with a light sweeping across them now and then.
// texture: assets/car.jpg
// texture1: assets/car_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float kGroundTop = 690.0;            // where the wet ground starts

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = smoke, g = wet ground, b = taillights.
float3 effects(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return effects(q).r; }
#include "fx.hlsli"

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 fx = effects(q);
    float2 qs = q;

    // The wet ground: a gentle shimmer and rings from the raindrops.
    float2 rings = 0;
    if (fx.g > 0.0) {
        float near = saturate((q.y - kGroundTop) / 250.0);
        float phase = 2600.0 / (q.y - kGroundTop + 25.0);
        qs.x += fx.g * near * 2.5 * sin(phase - t * 1.3 + sin(q.x / 70.0 + t * 0.5) * 1.5);
        rings = waterRings(q, t, kGroundTop, 836.0, 0.4, 0.75, float2(0.7, 1.6), 0.5, 0.45) * fx.g;
        qs.y += rings.y * 2.5 * (0.3 + near);
    }

    // The picture's smoke rolls up and away from the car on both sides.
    float3 col = fx.g > 0.0 ? picture(qs) : streamSmoke(q, t, float2(q.x < 836.0 ? -10.0 : 10.0, -9.0));
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    col += col * fx.r * smokeWisps(q, t) * 0.5;

    // More smoke: around the smoke that's there, and a low layer rolling along the ground, in front
    // of the wheels too.
    float around = max(max(effects(q + float2(90.0, 0.0)).r, effects(q - float2(90.0, 0.0)).r), effects(q - float2(0.0, 90.0)).r);
    float low = smoothstep(560.0, 680.0, q.y) * smoothstep(820.0, 730.0, q.y);
    float region = saturate(max(fx.r, around * 0.8) * smoothstep(760.0, 700.0, q.y) + low * 0.75);
    if (region > 0.01) {
        float d = smokeDensity(q, t, float2(-14.0, -5.0), 210.0) * region;
        col += smokeLight(q, float3(0.08, 0.08, 0.085)) * d * 0.85;
    }

    // Taillights breathe; every six seconds a light sweeps across them, mirrored in the puddles.
    float breathe = 0.5 + 0.5 * sin(t * 1.2);
    float sx = lerp(820.0, 1520.0, frac(t / 6.0) * 1.5 - 0.25);
    float sweep = exp(-pow((q.x - sx) / 45.0, 2.0));
    col += col * fx.b * (0.2 * breathe + 1.4 * sweep);
    float redness = saturate((col.r - max(col.g, col.b)) * 2.0);
    col += col * fx.g * redness * (0.15 * breathe + 0.5 * exp(-pow((q.x - sx) / 70.0, 2.0)));

    // Splashes light up on the ground; drops glint on the paint.
    col += (0.025 + col * 0.9) * rings.x;
    float onCar = (1.0 - fx.r) * (1.0 - fx.g) * (1.0 - fx.b);
    col += float3(0.9, 0.9, 1.0) * twinkle(q, t, 4.0, 30.0) * smoothstep(0.35, 0.7, lum) * onCar * 0.7;

    // Rain falling past the camera, catching the light around it.
    float3 rainLight = 0.18 + col * 1.6;
    float r = rain(p, t, 0.05, 1.6, 0.035, 0.35, 1.0, 0.12, px) * 0.5;
    r += rain(p, t, 0.08, 2.2, 0.06, 0.25, 7.0, 0.12, px * 1.6) * 0.6;
    col += rainLight * r;
    return float4(col, 1.0);
}
