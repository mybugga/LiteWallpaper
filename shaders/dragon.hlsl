// Dragon: a black dragon veined with fire. Every ten seconds it breathes a roaring blast of fire out
// of its open jaws that lights up its face; flames lick up along the bottom and light it from below.
// The molten cracks glow and flow, its eye burns brighter and dimmer, its throat glows, smoke streams
// from its jaws between blasts, smoke rolls around its feet, embers rise, and it breathes slowly
// while its wings flex.
// texture: assets/dragon.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);    // picture pixels the positions below use
static const float2 kEye = float2(1160.0, 290.0);
static const float2 kMouth = float2(1235.0, 470.0);  // where the smoke leaves the jaws
static const float2 kJaws = float2(1262.0, 480.0);   // where the fire leaves the open jaws
static const float2 kChest = float2(880.0, 941.0);   // it breathes about here
static const float2 kWingL = float2(430.0, 620.0);   // where each wing flexes from
static const float2 kWingR = float2(1300.0, 660.0);

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// The head's outline on the right at height y (snout, fangs, lower jaw), traced from the picture.
float headEdge(float y) {
    if (y < 300.0) return lerp(1290.0, 1320.0, saturate((y - 200.0) / 100.0));
    if (y < 345.0) return lerp(1320.0, 1345.0, (y - 300.0) / 45.0);
    if (y < 440.0) return lerp(1345.0, 1322.0, (y - 345.0) / 95.0);
    if (y < 470.0) return lerp(1322.0, 1275.0, (y - 440.0) / 30.0);
    if (y < 530.0) return lerp(1275.0, 1258.0, (y - 470.0) / 60.0);
    return lerp(1258.0, 1150.0, saturate((y - 530.0) / 170.0));
}

// 1 away from the dragon, 0 on its head or right wing: the smoke's flow and the smoke drawn over the
// picture stay off them, so its face never ripples like smoke.
float notDragon(float2 q) {
    float edge = headEdge(q.y);
    float head = smoothstep(edge + 16.0, edge + 2.0, q.x);
    // The right wing's leading edge runs from (1350, 690) up to (1645, 245); the wing is beyond it.
    float2 d = normalize(float2(295.0, -445.0));
    float side = d.x * (q.y - 690.0) - d.y * (q.x - 1350.0);
    float wing = smoothstep(-18.0, -4.0, side);
    return (1.0 - head) * (1.0 - wing);
}

// Where the picture has smoke: in front of the jaws only.
float jawSmoke(float2 q) {
    float2 dm = q - kMouth;
    return smoothstep(0.0, 40.0, dm.x) * smoothstep(380.0, 250.0, dm.x) * smoothstep(170.0, 80.0, abs(dm.y + 40.0)) * notDragon(q);
}
float smokeMask(float2 q) { return jawSmoke(q); }
#include "fx.hlsli"

// Fire colour by heat: dark red, orange, yellow, then white-hot.
float3 fireRamp(float k) {
    return float3(1.0, 0.28, 0.05) * smoothstep(0.0, 0.45, k) + float3(0.0, 0.42, 0.12) * smoothstep(0.35, 0.8, k) +
           float3(0.0, 0.25, 0.4) * smoothstep(0.75, 1.0, k);
}

// The blast of fire from its jaws: once every ten seconds, about three seconds long. It rolls out of
// the open mouth and billows wider as it goes. Heat 0-1; `env` is how strong the blast is now (it
// also lights the face).
float breathFire(float2 q, float t, out float env) {
    float c = frac(t / 10.0) * 10.0;
    env = smoothstep(5.4, 5.9, c) * smoothstep(8.7, 7.9, c);
    if (env <= 0.001) return 0.0;
    float2 dir = normalize(float2(1.0, 0.12));  // forwards and a touch down, the way the head points
    float2 d = q - kJaws;
    float along = dot(d, dir), across = dot(d, float2(-dir.y, dir.x));
    if (along < -40.0) return 0.0;
    float reach = 110.0 + 470.0 * smoothstep(5.4, 6.2, c);  // the blast rolls out, then holds
    float width = 16.0 + max(along, 0.0) * 0.42;
    // Billows: noise carried outwards fast, folded by more noise.
    float2 w = float2(along / 75.0 - t * 4.0, across / 48.0);
    float2 fold = float2(fbm3(w + 1.3), fbm3(w + 6.1)) - 0.5;
    float n = fbm3(w * 1.3 + fold * 1.6);
    float n2 = fbm3(float2(along / 24.0 - t * 8.0 + 4.0, across / 16.0 + 2.0));
    float body = exp(-pow((across + fold.y * width * 1.3) / width, 2.0));
    float k = body * (0.3 + 0.95 * n) * (0.75 + 0.35 * n2);
    k *= smoothstep(-35.0, 5.0, along) * smoothstep(reach, reach - 170.0, along);
    k *= 1.0 - 0.5 * saturate(along / reach);  // hottest at the jaws
    return saturate(k * 1.25) * env;
}

// Flames licking up along the bottom of the scene, in patches with gaps between them that slowly
// shift. Heat 0-1.
float floorFire(float2 q, float t) {
    float h = kImg.y - q.y;  // picture pixels above the bottom edge
    if (h > 300.0) return 0.0;
    float patch = smoothstep(0.3, 0.62, fbm3(float2(q.x / 280.0 + 3.0, t * 0.07)));
    float tall = 40.0 + 220.0 * patch;
    float2 w = float2(q.x / 70.0, (q.y + t * 150.0) / 80.0);  // carried upwards
    float2 fold = float2(fbm3(w * 0.7 + 1.7), fbm3(w * 0.7 + 8.3)) - 0.5;
    float n = fbm3(w + fold * 1.2);
    float n2 = fbm3(float2(q.x / 30.0 + 5.0, (q.y + t * 230.0) / 26.0));
    float k = (n * 0.8 + n2 * 0.35) * (0.55 + 0.45 * patch) - h / tall;
    return saturate(k * 1.5) * 0.85;
}

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

    // The smoke in front of its jaws streams away and rises (only the smoke: never the dragon).
    float3 col = streamSmoke(qs, t, float2(22.0, -9.0));

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

    // The fire blast, and the light it throws on the face and jaws.
    float env;
    float fire = breathFire(q, t, env);
    float nearJaws = exp(-length((q - kJaws) * float2(0.8, 1.0)) / 170.0);
    col += col * float3(1.0, 0.45, 0.12) * env * nearJaws * 3.0 * (0.85 + 0.15 * sin(t * 23.0));
    col += float3(1.0, 0.35, 0.08) * env * nearJaws * 0.08;  // glow in the air round the mouth

    // Smoke streaming from the jaws between blasts, thickest as it breathes out.
    float2 dm = q - kMouth;
    float along = dm.x;
    if (along > -10.0 && along < 420.0) {
        float spread = 12.0 + along * 0.35;
        float centre = -along * 0.28 - 0.0004 * along * along;  // rises as it drifts away
        float plume = exp(-pow((dm.y - centre) / spread, 2.0)) * smoothstep(-10.0, 30.0, along) * exp(-along / 260.0);
        float puffs = fbm3(float2(along / 45.0 - t * 0.9, dm.y / 40.0 + t * 0.1));
        col += float3(0.5, 0.47, 0.47) * plume * smoothstep(0.35, 0.8, puffs) * (0.3 + 0.4 * breath) * (1.0 - 0.8 * env) * notDragon(q);
    }

    // Smoke rolling low around its feet, lit by the fire.
    float low = smoothstep(700.0, 900.0, q.y);
    if (low > 0.01) {
        float d = smokeDensity(q, t, float2(16.0, -5.0), 220.0) * low;
        col += float3(0.2, 0.08, 0.06) * d * 0.8;
    }

    // Flames along the bottom, and their flickering light on the dragon above them.
    float flicker = 0.8 + 0.2 * sin(t * 9.0) * sin(t * 13.7 + 1.0);
    col += col * float3(1.0, 0.38, 0.1) * smoothstep(560.0, 941.0, q.y) * 0.7 * flicker;
    float ff = floorFire(q, t);
    col += fireRamp(ff) * ff * 1.1;

    col += fireRamp(fire) * fire * 1.8;

    // Embers rising from the fire below.
    col += embers(p, t, 0.08, 0.05, 0.0012, 0.3, 3.0, px, float3(1.0, 0.35, 0.08));
    col += embers(p, t, 0.15, 0.09, 0.002, 0.22, 9.0, px, float3(1.0, 0.45, 0.12)) * 0.8;
    return float4(col, 1.0);
}
