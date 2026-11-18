// Lighthouse: a lighthouse on a rock in a dark sea. Its beam turns round and round: it sweeps out to
// the left through the haze, flashes as it faces you, sweeps out to the right and passes behind the
// tower. The sea rolls, waves break on the rocks throwing up spray, and the lamp's gold reflection
// shimmers on the water and flares with each flash.
// texture: assets/lighthouse.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float2 kLamp = float2(1423.0, 322.0);
static const float2 kWindow = float2(1432.0, 398.0);
static const float kSea = 700.0;                   // the sea's surface starts here
static const float kTurn = 9.0;                    // seconds for the light to go round once

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// The spray thrown up round the rocks: bright, white, just above the sea.
float smokeMask(float2 q) {
    float band = smoothstep(585.0, 610.0, q.y) * smoothstep(712.0, 698.0, q.y) * smoothstep(970.0, 1000.0, q.x) * smoothstep(1440.0, 1400.0, q.x);
    float3 c = picture(q);
    float white = smoothstep(0.35, 0.6, dot(c, float3(0.3, 0.5, 0.2))) * (1.0 - saturate((max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))) * 3.0));
    return band * white;
}
#include "fx.hlsli"

// Spray leaping where a wave breaks on the rocks, falling back.
float3 breakingSpray(float2 q, float t, float2 at, float phase) {
    float3 col = 0;
    float cyc = frac(t / 6.0 + phase);
    if (cyc > 0.35) return 0;
    float age = cyc * 6.0;
    [unroll] for (int i = 0; i < 14; i++) {
        float h1 = hash21(float2(i, phase * 91.0)), h2 = hash21(float2(i + 30.0, phase * 91.0));
        float2 v = float2((h1 - 0.5) * 110.0, -(90.0 + 120.0 * h2));
        float2 pos = at + float2((h2 - 0.5) * 40.0, 0.0) + v * age + float2(0.0, 0.5 * 300.0 * age * age);
        if (pos.y > at.y + 6.0) continue;
        float d = length(q - pos);
        float s = 1.2 + 1.6 * hash21(float2(i + 60.0, phase * 91.0));
        col += float3(0.85, 0.9, 0.95) * exp(-d * d / (2.0 * s * s)) * (1.0 - age / 2.1);
    }
    return col;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The beam's direction: x across the screen, z toward you.
    float phi = t * 6.2832 / kTurn + 2.6;
    float2 dir = float2(cos(phi), sin(phi));
    float facing = pow(saturate(dir.y), 10.0);  // flash as it points at you

    // The sea rolls: waves travel across, larger and slower near you, small and quick far off.
    float2 qs = q;
    float sea = smoothstep(kSea - 6.0, kSea + 10.0, q.y);
    if (sea > 0.0) {
        float depth = saturate((q.y - kSea) / 240.0);
        float2 w = float2(q.x / (40.0 + 170.0 * depth), (q.y - kSea) / (7.0 + 30.0 * depth));
        float roll = sin(q.x / (70.0 + 260.0 * depth) + t * (1.1 - 0.4 * depth) - (q.y - kSea) / (10.0 + 40.0 * depth));
        qs.x += ((noise(w + float2(t * 0.45, t * 0.15)) - 0.5) * (4.0 + 12.0 * depth)) * sea;
        qs.y += ((noise(w * 1.3 + float2(-t * 0.35, 7.0)) - 0.5) * (2.0 + 6.0 * depth) + roll * (1.0 + 4.0 * depth)) * sea;
    }
    float3 col = smokeMask(q) > 0.001 ? streamSmoke(q, t, float2(0.0, -26.0)) : picture(qs);
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // The lamp's gold reflection shimmers, and flares with each flash.
    float column = sea * exp(-pow((q.x - 1410.0) / 130.0, 2.0));
    float glitter = noise(float2(q.x / 6.0, (q.y + t * 25.0) / 3.0));
    float warmth = saturate((col.r - col.b) * 4.0);
    col += col * column * warmth * ((glitter - 0.4) * 1.2 + 2.0 * facing);

    // The turning beam: a cone of light through drifting haze, foreshortened as it turns toward or
    // away from you, dimmer as it shines away (haze scatters light mostly forward), and hidden
    // close to the lamp while it's behind the lantern.
    float side = dir.x >= 0.0 ? 1.0 : -1.0;
    float along = (q.x - kLamp.x) * side;
    float reach = 950.0 * abs(dir.x) + 50.0;
    float centre = kLamp.y + along * 0.025;
    float width = 7.0 + along * 0.12;
    float haze = 0.6 + 0.4 * fbm3(q / 85.0 + float2(t * 0.05, -t * 0.01));
    float beam = exp(-pow((q.y - centre) / width, 2.0)) * smoothstep(-6.0, 26.0, along) * exp(-along / (reach * 0.55)) * smoothstep(reach * 1.5, reach * 0.4, along);
    float behind = saturate(-dir.y * 3.0);
    beam *= lerp(1.0, smoothstep(14.0, 70.0, along), behind);
    beam *= (0.25 + 0.75 * pow(0.5 + 0.5 * dir.y, 2.0)) * haze;
    col += float3(1.0, 0.78, 0.5) * beam * 0.55;

    // The lamp: always lit, blazing with rays as the beam faces you.
    float rl = length(q - kLamp);
    float2 dl = (q - kLamp) / kImg.y;
    float rays = exp(-abs(dl.y) / 0.0022) * exp(-abs(dl.x) / (0.02 + 0.075 * facing)) + exp(-abs(dl.x) / 0.0022) * exp(-abs(dl.y) / (0.015 + 0.05 * facing));
    col += float3(1.0, 0.8, 0.55) * (exp(-rl / 14.0) * (0.15 + 0.9 * facing) + exp(-rl / 120.0) * 0.4 * facing + rays * facing * 0.5);
    // The haze and the rocks light up a little in the flash.
    col += col * facing * 0.25 * exp(-rl / 500.0);

    // The window flickers like a fire inside.
    float rw = length((q - kWindow) * float2(1.0, 0.7));
    col += float3(1.0, 0.6, 0.25) * exp(-rw / 4.0) * 0.18 * (noise(float2(t * 5.0, 3.0)) - 0.3);

    // Waves breaking on the rocks, one after another along the shore.
    col += breakingSpray(q, t, float2(1045.0, 660.0), 0.0);
    col += breakingSpray(q, t, float2(1130.0, 672.0), 0.27);
    col += breakingSpray(q, t, float2(1265.0, 672.0), 0.52);
    col += breakingSpray(q, t, float2(1355.0, 690.0), 0.78);
    return float4(col, 1.0);
}
