// Ribbon: glossy glass ribbons twisting through the dark, with pink and blue light streaming to
// the right through them like light through fibre optics. Waves roll along them like silk in a
// breeze and the strands slowly swell and narrow as if twisting; bright pulses race along their
// glowing edges, a sheen sweeps across every few seconds, and sparks fly off the glowing strands.
// texture: assets/ribbon.jpg
// texture1: assets/ribbon_flow.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float kMiddle = 470.0;                // the ribbons twist about this height

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// Which way the ribbon runs at q (pointing right), and how much it glows there.
float3 flowMap(float2 q) {
    float3 f = iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb;
    return float3(normalize(f.xy * 2.0 - 1.0 + float2(0.001, 0.0)), f.z);
}

// Turns a colour's hue by `angle` radians, keeping its brightness.
float3 shiftHue(float3 c, float angle) {
    const float3 k = float3(0.57735, 0.57735, 0.57735);
    float ca = cos(angle);
    return c * ca + cross(k, c) * sin(angle) + k * dot(k, c) * (1.0 - ca);
}

// Sparks thrown off the ribbon. Each starts on a glowing spot, in that spot's colour, streams
// away to the right along the ribbon and a little outward, and fades. Sparks are kept in a grid
// of `cell`-pixel cells by where they start; a pixel checks the cells a spark could reach it from
// (two to the left, one to the right, one above or below), so each spark's travel and glow are
// kept within that reach (cells must be 80+ pixels).
float3 ribbonSparks(float2 q, float t, float cell, float chance, float sizeScale, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int dx = -2; dx <= 1; dx++)
    [unroll] for (int dy = -1; dy <= 1; dy++) {
        float2 id = base + float2(dx, dy);
        if (hash21(id + seed) > chance) continue;
        float2 spawn = (id + float2(hash21(id + seed + 1.0), hash21(id + seed + 2.0))) * cell;
        float3 fm = flowMap(spawn);
        if (fm.z < 0.2) continue;  // only from glowing parts of the ribbon
        float period = 1.6 + 1.4 * hash21(id + seed + 3.0);
        float life = period * 0.85;
        float age = frac(t / period + hash21(id + seed + 4.0)) * period;
        if (age > life) continue;
        float speed = min(35.0 + 25.0 * hash21(id + seed + 5.0), 1.5 * cell / life);
        float side = hash21(id + seed + 6.0) > 0.5 ? 1.0 : -1.0;
        float2 v = fm.xy * speed + float2(-fm.y, fm.x) * side * speed * 0.35;
        v.y = clamp(v.y, -0.4 * speed, 0.4 * speed);  // stays within the cells checked
        float2 pos = spawn + v * age + float2(0.0, 6.0 * sin(age * 3.0 + seed));
        float size = (1.0 + 1.5 * pow(hash21(id + seed + 7.0), 3.0)) * sizeScale;
        // A short trail behind it, along the way it came.
        float2 back = -normalize(v) * min(speed * 0.18, 9.0);
        float2 pa = q - pos;
        float d = length(pa - back * saturate(dot(pa, back) / dot(back, back)));
        float dHead = length(pa);
        float fade = smoothstep(0.0, 0.15, age) * pow(1.0 - age / life, 1.5);
        float3 c = picture(spawn);
        c = lerp(c / max(max(c.r, max(c.g, c.b)), 0.05), 1.0, 0.25);  // its colour, at full glow
        col += c * (exp(-dHead * dHead / (2.0 * size * size)) * 1.4 + exp(-d * d / (2.0 * size * size * 0.4)) * 0.6 +
                   exp(-dHead / (size * 5.0)) * 0.5) * fade * smoothstep(24.0, 12.0, d);
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

    // Waves travel along the ribbons, left to right, a long slow one and a shorter quicker one.
    float2 qs = q;
    qs.y -= 18.0 * sin(q.x / 270.0 - t * 0.8) + 7.0 * sin(q.x / 115.0 - t * 1.5 + 1.0);
    qs.x -= 6.0 * sin(q.y / 160.0 + t * 0.5);
    // The strands swell apart and draw together, as if the ribbon were twisting.
    qs.y = kMiddle + (qs.y - kMiddle) / (1.0 + 0.05 * sin(q.x / 360.0 - t * 0.6));

    // The glowing light streams to the right along the ribbon's own curves: two copies slide along
    // it, each fading out as the other fades in, so it flows on and on (a flow map). The dark glass
    // stays where it is.
    float3 col = picture(qs);
    float3 fm = flowMap(qs);
    if (fm.z > 0.01) {
        const float period = 1.6, travel = 120.0;
        float ph1 = frac(t / period), ph2 = frac(t / period + 0.5);
        float w1 = 1.0 - abs(2.0 * ph1 - 1.0);
        float3 flowed = picture(qs - fm.xy * travel * (ph1 - 0.5)) * w1 + picture(qs - fm.xy * travel * (ph2 - 0.5)) * (1.0 - w1);
        col = lerp(col, flowed, fm.z);
    }
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float sat = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));
    float glowing = smoothstep(0.08, 0.3, sat) * smoothstep(0.05, 0.3, lum);

    // The pink and blue flow along the ribbons: waves of hue travel left to right, turning blue
    // toward violet and pink (never the other way, which would go green).
    float hue = 0.38 * (1.0 + sin(qs.x / 380.0 - t * 0.55 + qs.y / 600.0)) + 0.1 * sin(qs.x / 150.0 - t * 1.1);
    col = lerp(col, max(shiftHue(col, hue), 0.0), glowing);

    // Bright pulses race to the right along the glowing edges, each with a fading tail behind it;
    // different strands get them at different moments.
    float race = frac((qs.x - t * 320.0) / 520.0 + 0.35 * noise(float2(qs.y / 140.0, 3.0)));
    float pulse = pow(race, 10.0) * smoothstep(1.0, 0.97, race);
    col += (col * 1.6 + float3(0.08, 0.05, 0.12)) * pulse * glowing * 1.3;

    // A sheen sweeps across every seven seconds, catching the brightest curves.
    float sx = lerp(-300.0, kImg.x + 300.0, frac(t / 7.0));
    float sheen = exp(-pow((q.x - sx + (q.y - kMiddle) * 0.3) / 90.0, 2.0));
    col += (col * 1.2 + 0.05) * sheen * smoothstep(0.15, 0.6, lum);

    // Sparks fly off the glowing strands; they ride the waves with the ribbon.
    col += ribbonSparks(qs, t, 85.0, 0.95, 2.2, 1.0);
    col += ribbonSparks(qs, t, 80.0, 0.95, 1.5, 17.0);
    col += ribbonSparks(qs, t, 100.0, 0.9, 2.8, 31.0) * 0.9;
    col += ribbonSparks(qs, t, 90.0, 0.95, 1.8, 47.0);
    return float4(col, 1.0);
}
