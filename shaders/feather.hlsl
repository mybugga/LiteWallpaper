// Feather: a black feather burning along one edge, drifting in the dark. It floats and turns gently
// as it hangs in the air; the fire flickers and creeps along its burning edge, flames lick up off
// it, embers break away and drift upward, smoke streams up with more rising off the fire, and the
// down at its base flutters in the heat.
// texture: assets/feather.jpg
// texture1: assets/feather_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);       // picture pixels the positions below use
static const float2 kCentre = float2(1260.0, 480.0);    // middle of the feather
static const float2 kEdgeTop = float2(1560.0, 170.0);  // the burning edge, from its top...
static const float2 kEdgeEnd = float2(1300.0, 660.0);  // ...to its lower end
static const float2 kDown = float2(975.0, 680.0);      // the fluffy down at its base

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = the feather with its flames (floats as one piece), g = smoke, b = flame tongues off the edge.
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).g; }
#include "fx.hlsli"

// How much a colour is fire.
float fireAmt(float3 c) { return saturate(((c.r - c.b) / max(c.r, 0.02) - 0.55) * 3.0) * smoothstep(0.22, 0.65, c.r); }

// The feather's drift: it turns a little and bobs, slowly, like something hanging in warm air.
float driftAngle(float t) { return 0.022 * sin(t * 0.45) + 0.008 * sin(t * 1.1 + 1.0); }
float2 driftOffset(float t) { return float2(6.0 * sin(t * 0.33), 9.0 * sin(t * 0.5 + 0.7)); }

// Where a screen point is on the floating feather (picture pixels before it moved).
float2 toFeather(float2 q, float t) {
    return kCentre + rot(q - kCentre - driftOffset(t), -driftAngle(t));
}
// And back: where a point of the feather is on screen now.
float2 fromFeather(float2 f, float t) {
    return kCentre + rot(f - kCentre, driftAngle(t)) + driftOffset(t);
}

// The flame tongues off the edge rise: two copies slide up, each fading out as the other fades in.
float3 risingFlames(float2 f, float t, float3 here) {
    const float period = 0.45;
    float offset = noise(f / float2(35.0, 70.0));
    float ph1 = frac(t / period + offset), ph2 = frac(t / period + offset + 0.5);
    float w1 = 1.0 - abs(2.0 * ph1 - 1.0);
    float2 sway = float2(5.0 * sin(f.y / 24.0 + t * 3.1), 0.0);
    float2 s1 = f + float2(0.0, 70.0 * period * (ph1 - 0.5)) + sway * ph1;
    float2 s2 = f + float2(0.0, 70.0 * period * (ph2 - 0.5)) + sway * ph2;
    return picture(s1) * w1 + picture(s2) * (1.0 - w1);
}

// The burning edge, as a line along the feather (picture pixels before it moved).
static const float2 kEdge[9] = { float2(1562.0, 170.0), float2(1585.0, 240.0), float2(1578.0, 320.0), float2(1550.0, 400.0),
                                 float2(1510.0, 470.0), float2(1460.0, 530.0), float2(1400.0, 590.0), float2(1330.0, 640.0),
                                 float2(1260.0, 680.0) };
float2 edgePoint(float u) {
    float x = saturate(u) * 7.999;
    int k = (int)floor(x);
    return lerp(kEdge[k], kEdge[k + 1], frac(x));
}

// Embers breaking off the burning edge: each leaves a random point along it (more from the hotter
// upper part), drifts up and a little to the right, swaying, with a short glowing streak, flickering
// and cooling from yellow to deep red as it fades; then another takes its place somewhere else.
float3 embersOff(float2 q, float t) {
    float3 col = 0;
    [loop] for (int i = 0; i < 56; i++) {
        float h0 = hash21(float2(i, 3.1));
        float period = 1.7 + 2.0 * hash21(float2(i, 5.7));
        float cyc = t / period + h0;
        float age = frac(cyc) * period;
        float2 id = float2(i, floor(cyc));
        float life = period * 0.9;
        if (age > life) continue;
        float u = 0.92 * pow(hash21(id + 0.7), 1.35);  // more from the upper edge
        float2 e = normalize(edgePoint(u + 0.02) - edgePoint(u));
        float2 outward = float2(e.y, -e.x);  // away from the feather (the edge runs down its right side)
        float2 start = fromFeather(edgePoint(u) + outward * 3.0, t - age);
        // Thrown out from the edge, slowing, while the heat carries it up and the air drifts right.
        float push = (25.0 + 30.0 * hash21(id + 8.8)) * age * (1.0 - 0.5 * saturate(age / 1.2));
        float2 v = float2(6.0 + 20.0 * hash21(id + 2.3), -(35.0 + 55.0 * hash21(id + 4.1)));
        float2 pos = start + outward * push + v * age + float2(9.0 * sin(age * 2.4 + h0 * 20.0) * saturate(age), -3.0 * age * age);
        float2 rel = q - pos;
        if (abs(rel.x) > 24.0 || abs(rel.y) > 30.0) continue;
        float2 back = -normalize(v) * 6.0;  // a short streak behind it
        float d = length(rel - back * saturate(dot(rel, back) / dot(back, back)));
        float dh = length(rel);
        float sz = 1.2 + 1.8 * pow(hash21(id + 6.6), 2.0);
        float k = age / life;
        float fade = smoothstep(0.0, 0.08, k) * pow(1.0 - k, 1.2);
        float flicker = 0.6 + 0.4 * sin(t * (13.0 + 6.0 * h0) + h0 * 40.0);
        float3 hot = lerp(float3(1.0, 0.85, 0.45), float3(0.9, 0.2, 0.03), saturate(k * 1.3));
        col += hot * (exp(-dh * dh / (2.0 * sz * sz)) * 1.7 + exp(-d * d / (2.0 * sz * sz * 0.35)) * 0.6 + exp(-dh / (sz * 4.0)) * 0.3) * fade * flicker;
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

    // The feather (with its flames) floats; the smoke around it stays in the air.
    float2 f = toFeather(q, t);
    float body = parts(f).r;
    float2 qs = lerp(q, f, body);

    // The down at its base flutters in the rising heat.
    float down = body * smoothstep(150.0, 70.0, length(qs - kDown));
    qs += (float2(noise(qs / 9.0 + t * 2.2), noise(qs / 9.0 + 5.0 - t * 1.9)) - 0.5) * 3.0 * down;

    // Heat shimmer above the fire.
    float aboveFire = smoothstep(380.0, 150.0, q.y) * smoothstep(1400.0, 1500.0, q.x) * (1.0 - body * 0.7);
    qs += (float2(noise(q / 12.0 + float2(0.0, t * 2.5)), noise(q / 12.0 + float2(4.0, t * 2.3))) - 0.5) * 2.4 * aboveFire;

    float3 col = body > 0.5 ? picture(qs) : streamSmoke(q, t, float2(-5.0, -18.0));
    float tongues = parts(qs).b * body;
    if (tongues > 0.001) col = lerp(col, risingFlames(qs, t, col), tongues);
    float fire = fireAmt(col);

    // The fire flickers and creeps along the burning edge.
    float2 ed = normalize(kEdgeEnd - kEdgeTop);
    float along = dot(qs - kEdgeTop, ed);
    float creep = pow(0.5 + 0.5 * sin(along / 26.0 - t * 2.4 + 2.0 * noise(float2(along / 80.0, t * 0.3))), 4.0);
    float flick = noise(float2(qs.y / 35.0 + t * 3.2, qs.x / 35.0)) - 0.45;
    col += col * fire * (0.9 * flick + 0.9 * creep);

    // Flames licking up off the burning edge: they rise over the parts that are on fire.
    float below = 0.0;
    [unroll] for (int k = 1; k <= 4; k++) {
        float2 b = qs + float2(0.0, 9.0 * k);
        float solid = (fireAmt(picture(b)) + fireAmt(picture(b + float2(5.0, 0.0))) + fireAmt(picture(b - float2(5.0, 0.0))) +
                       fireAmt(picture(b + float2(0.0, 5.0)))) * 0.25;  // solid fire, not a loose speck
        below = max(below, smoothstep(0.35, 0.7, solid) * (1.0 - 0.18 * k));
    }
    if (below > 0.05) {
        float n = fbm3(float2(qs.x / 11.0, (qs.y + t * 85.0) / 17.0));
        float lick = smoothstep(0.45, 0.8, n) * below * body;
        col += lerp(float3(1.0, 0.28, 0.04), float3(1.0, 0.75, 0.3), smoothstep(0.55, 0.85, n)) * lick * 0.75;
    }
    // Its glow spills onto the feather round it.
    if (body > 0.5) {
        float halo = 0.0;
        [unroll] for (int i = 0; i < 8; i++) {
            float a = i * 0.785;
            halo += fireAmt(picture(qs + float2(cos(a), sin(a)) * 11.0));
        }
        col += float3(1.0, 0.32, 0.06) * halo / 8.0 * (0.08 + 0.06 * sin(t * 2.0));
    }

    // Smoke rising off the fire.
    float rise = smoothstep(560.0, 300.0, q.y) * smoothstep(1400.0, 1500.0, q.x) * (1.0 - body * 0.85);
    rise = max(rise, smoothstep(330.0, 120.0, q.y) * smoothstep(1180.0, 1300.0, q.x) * smoothstep(1600.0, 1480.0, q.x) * (1.0 - body) * 0.6);
    if (rise > 0.01) {
        float d = smokeDensity(q, t, float2(-10.0, -26.0), 110.0) * rise;
        float warm = exp(-length((q - float2(1545.0, 400.0)) / float2(120.0, 160.0)));
        col += lerp(float3(0.12, 0.118, 0.115), float3(0.2, 0.12, 0.07), warm) * d * 0.85;
    }

    // Embers breaking off and drifting up.
    if (q.x > 1150.0 && q.y < 760.0) col += embersOff(q, t);
    return float4(col, 1.0);
}
