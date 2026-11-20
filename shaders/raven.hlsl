// Raven: a clockwork raven perched on a rock. Its head moves in quick little turns like a real
// bird's and its chest rises and falls; the gear in its shoulder turns, its glowing eye pulses as
// the pupil narrows and widens, gusts of wind ruffle its feathers, copper parts catch the light,
// and dust drifts in the warm glow.
// texture: assets/raven.jpg
// scale: 1
// focus: 0.69
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kGear = float2(1419.0, 291.0);
static const float kGearR = 54.0;
static const float2 kEye = float2(1063.0, 105.0);
static const float2 kHead = float2(1050.0, 130.0);  // middle of the head
static const float2 kNeck = float2(1130.0, 300.0);  // the head turns about here
static const float2 kFeet = float2(1300.0, 900.0);  // it breathes about here

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// The head holds still, then snaps quickly to a new angle, like a bird looking about.
float headAngle(float t) {
    float k = floor(t / 3.3), ph = frac(t / 3.3) * 3.3;
    float a0 = (hash21(float2(k - 1.0, 3.0)) - 0.5) * 0.075;
    float a1 = (hash21(float2(k, 3.0)) - 0.5) * 0.075;
    return lerp(a0, a1, smoothstep(0.0, 0.22, ph));
}

// Where the feathers are (the wind moves them): not the gear, eye, beak, the copper pipes in the
// chest, the legs or the rock.
float featherWeight(float2 q) {
    float w = smoothstep(kGearR + 6.0, kGearR + 26.0, length(q - kGear));
    w *= smoothstep(20.0, 40.0, length(q - kEye));
    w *= 1.0 - smoothstep(1020.0, 990.0, q.x) * smoothstep(270.0, 240.0, q.y);
    float pipes = smoothstep(1140.0, 1160.0, q.x) * smoothstep(1270.0, 1250.0, q.x) * smoothstep(200.0, 220.0, q.y) * smoothstep(470.0, 450.0, q.y);
    float legs = smoothstep(540.0, 600.0, q.y) * smoothstep(1060.0, 1100.0, q.x) * smoothstep(1560.0, 1500.0, q.x);
    return w * (1.0 - pipes) * (1.0 - legs) * (1.0 - smoothstep(720.0, 780.0, q.y));
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // Breathing: the chest swells a little about the feet.
    float breath = sin(t * 1.3);
    float2 qs = kFeet + (q - kFeet) / (1.0 + 0.0045 * breath);

    // The head: quick turns about the neck.
    float ha = headAngle(t);
    float hw = smoothstep(265.0, 180.0, length(q - kHead));
    qs = lerp(qs, kNeck + rot(qs - kNeck, -ha), hw);

    // Gusts of wind sweep across and ruffle the feathers, most at their tips.
    float fw = featherWeight(q);
    if (fw > 0.001) {
        float gust = smoothstep(0.3, 0.8, noise(float2(q.x / 260.0 + t * 0.4, q.y / 500.0)));
        float2 ruffle = float2(noise(q / 13.0 + float2(t * 1.7, 0.0)), noise(q / 13.0 + float2(5.0, t * 1.5))) - 0.5;
        qs += ruffle * (1.6 + 3.4 * gust) * fw;
    }

    // The eye: the pupil narrows and widens.
    float re = length(qs - kEye);
    if (re < 15.0) {
        float zoom = 1.0 + 0.2 * sin(t * 0.8) + 0.06 * sin(t * 2.9);
        qs = kEye + (qs - kEye) / lerp(zoom, 1.0, smoothstep(8.0, 15.0, re));
    }

    float3 col = picture(qs);

    // The shoulder gear turns.
    float rgear = length(qs - kGear);
    if (rgear < kGearR + 2.0) {
        float2 src = kGear + rot(qs - kGear, -t * 0.45);
        col = lerp(col, picture(src), smoothstep(kGearR + 2.0, kGearR - 3.0, rgear));
    }

    // The eye's glow pulses, a soft light spilling round it.
    float2 eyeAt = kNeck + rot(kEye - kNeck, ha);
    float rEye = length(q - eyeAt);
    float pulse = 0.6 + 0.4 * sin(t * 0.8 + 0.6) + 0.08 * sin(t * 6.0);
    col += float3(1.0, 0.62, 0.22) * (exp(-rEye / 5.0) * 0.35 + exp(-rEye / 26.0) * 0.12) * pulse;

    // Copper parts and feather edges catch the light now and then.
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float copper = saturate((col.r - col.b) * 3.0) * smoothstep(0.32, 0.65, lum) * smoothstep(25.0, 40.0, rEye);
    col += float3(1.0, 0.75, 0.45) * twinkle(qs, t, 4.0, 34.0) * copper * 0.9;

    // Dust drifting in the warm light round it.
    float2 sp = float2(p.x / aspect, p.y);
    float light = smoothstep(0.85, 0.2, length((sp - float2(0.72, 0.62)) * float2(1.4, 1.0)));
    float dust = motes(p, t, 0.07, 0.0015, 0.3, 3.0, px) + motes(p, t, 0.12, 0.004, 0.2, 11.0, px) * 0.6;
    col += float3(1.0, 0.7, 0.4) * dust * light * 0.3;
    return float4(col, 1.0);
}
