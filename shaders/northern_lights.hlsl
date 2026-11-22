// Northern lights: green aurora over snowy mountains and a still lake. The aurora's curtains sway
// and fold, rays of light shimmer and run along them and the whole display pulses slowly brighter
// and dimmer; the lake ripples gently, its reflection swaying and pulsing with the sky, and the
// snow on the peaks catches the aurora's light.
// texture: assets/northern_lights.jpg
// texture1: assets/northern_lights_fx.png
// texture_portrait: assets/northern_lights_portrait.jpg
// texture1_portrait: assets/northern_lights_portrait_fx.png
// scale: 1
// focus: 0.3
// focus_portrait: 0.5
#include "space.hlsli"

#ifdef PORTRAIT
static const float2 kImg = float2(1440.0, 2560.0);
static const float kShore = 2192.0;  // picture pixels: where the lake starts
#else
static const float2 kImg = float2(2560.0, 1440.0);
static const float kShore = 1300.0;
#endif

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// fx: r = sky (above the ridge); g, b = the ridge line's height, smoothed: a 16-bit fraction of
// the picture's height (g low byte, b high byte)
float3 masks(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float ridgeAt(float3 m) { return (m.b * 65280.0 + m.g * 255.0) / 65535.0 * kImg.y; }

// How the aurora moves at a point of the sky: the curtains sway and fold (a displacement that
// grows with height above the ridge), and the light along them shimmers and pulses.
float2 curtainShift(float2 q, float t, float lift) {
    float fold = sin(q.y / 150.0 - t * 0.42 + q.x / 520.0) + 0.6 * sin(q.y / 63.0 + t * 0.31 - q.x / 300.0);
    float drift = (fbm(float2(q.x / 700.0 + t * 0.05, q.y / 260.0 - t * 0.08)) - 0.5) * 2.0;
    return float2(fold * 16.0 + drift * 30.0, (noise(float2(q.x / 240.0, t * 0.2)) - 0.5) * 10.0) * lift;
}

float curtainLight(float2 q, float t) {
    // Rays: thin upright streaks of light running sideways along the curtain.
    float rays = noise(float2(q.x / 11.0 + t * 0.9, q.y / 420.0 - t * 0.15));
    rays = 0.65 + 0.7 * pow(rays, 1.5);
    // Brighter patches roll along the curtain and the whole display slowly breathes.
    float wave = 0.82 + 0.3 * sin(q.x / 210.0 - t * 0.9 + noise(q / 400.0) * 3.0);
    float breath = 0.88 + 0.16 * sin(t * 0.35) + 0.06 * sin(t * 1.3);
    return rays * wave * breath;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 m = masks(q);
    float sky = m.r, lake = saturate((q.y - kShore) / 10.0);
    float ridgeY = ridgeAt(m);
    float3 col;

    if (lake > 0.001) {
        // The lake: the reflection of the sky point straight across the shore, rippling. Ripples
        // grow towards the near shore, breaking the reflection into swaying bands.
        float depth = saturate((q.y - kShore) / (kImg.y - kShore));
        float ripple = (noise(float2(q.x / 90.0, q.y / (5.0 + 9.0 * depth) - t * 0.55)) - 0.5) * (6.0 + 22.0 * depth)
                     + sin(q.y / (3.0 + 5.0 * depth) - t * 1.6) * (1.0 + 2.5 * depth);
        float2 mirror = float2(q.x, 2.0 * kShore - q.y);
        float lift = saturate((ridgeAt(masks(mirror)) - mirror.y) / 400.0);
        float2 shift = curtainShift(mirror, t, lift);
        float3 c = picture(q + float2(ripple + shift.x, 0.0));
        float green = saturate((c.g - max(c.r, c.b)) * 5.0);
        c *= lerp(1.0, curtainLight(mirror + shift, t), green * 0.85);
        col = lerp(picture(q), c, lake);
    } else {
        // The sky: only the aurora moves (it's light, so the sky behind is simply black).
        float lift = saturate((ridgeY - q.y) / 400.0);
        float2 shift = curtainShift(q, t, lift) * sky;
        float3 c = picture(q - shift);
        float green = saturate((c.g - max(c.r, c.b)) * 5.0);
        c *= lerp(1.0, curtainLight(q - shift, t), green * sky);
        col = c;

        // The snow on the peaks catches the aurora's light just below the ridge.
        float below = q.y - ridgeY;
        if (sky < 0.999) {
            float3 base = picture(q);
            float pale = smoothstep(0.25, 0.6, dot(base, float3(0.3, 0.5, 0.2))) * (1.0 - saturate((base.g - base.r) * 3.0));
            float near = exp(-max(below, 0.0) / 90.0);
            // How bright the aurora is above this peak right now.
            float above = curtainLight(float2(q.x, ridgeY - 120.0), t);
            col = base + float3(0.12, 0.55, 0.28) * pale * near * (above - 0.85) * 0.5;
            col = lerp(col, c, sky);
        }
    }
    return float4(max(col, 0.0), 1.0);
}
