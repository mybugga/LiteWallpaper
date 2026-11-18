// Sakura pond: a glowing cherry tree leans over dark water at night. Its branches sway in the wind
// and the blossoms pulse; neon petals tumble down on the breeze, show in the water as they near it
// and vanish into it; the water ripples so the reflections shimmer, and rings spread across it.
// texture: assets/sakura_pond.jpg
// scale: 1
#include "space.hlsli"
#include "falling.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
static const float kWaterTop = 700.0;              // the far edge of the water
static const float2 kPivot = float2(1560.0, 190.0);  // where the long branch leaves the trunk

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// How much of the tree at q moves: the branches and blossoms, not the lower trunk or rocks.
float treeWeight(float2 q) {
    return smoothstep(560.0, 480.0, q.y) * (1.0 - smoothstep(1480.0, 1560.0, q.x) * smoothstep(220.0, 300.0, q.y));
}

// How much of q is open water (not the rocks).
float waterWeight(float2 q) {
    float rocks = smoothstep(940.0, 990.0, q.x) * smoothstep(800.0, 760.0, q.y);
    return smoothstep(kWaterTop, kWaterTop + 15.0, q.y) * (1.0 - rocks);
}

// Rings spreading on the water, drawn in the water's own plane so they flatten with distance.
// Returns (ring brightness, ring push outward) at picture point q.
float2 ripples(float2 q, float t) {
    float depth = 240.0 / max(q.y - kWaterTop + 10.0, 1.0);  // 1 at the bottom, larger far away
    float2 w = float2((q.x - 836.0) * depth / 240.0, depth);
    float2 cellId = floor(w / 1.2);
    float bright = 0.0, push = 0.0;
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 id = cellId + float2(i, j);
        if (hash21(id + 4.0) > 0.55) continue;
        float period = 5.0 + 4.0 * hash21(id + 1.0);
        float lt = frac(t / period + hash21(id + 2.0)) * period;
        if (lt > 3.0) continue;
        float2 c = (id + 0.2 + 0.6 * float2(hash21(id + 3.0), hash21(id + 5.0))) * 1.2;
        float r = length(w - c);
        float ring = exp(-pow((r - lt * 0.32) / (0.025 * depth + 0.02), 2.0)) * (1.0 - lt / 3.0);
        bright += ring;
        push += ring * sign(r - lt * 0.32);
    }
    return float2(bright, push);
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The tree sways about its trunk, with gusts fluttering the blossoms.
    float tw = treeWeight(q);
    float2 qs = q;
    if (tw > 0.0) {
        float angle = radians(0.55 * sin(t * 0.5) + 0.25 * sin(t * 1.3 + 1.0) + 0.2 * sin(t * 0.21 + 2.0));
        qs += (kPivot + rot(q - kPivot, angle) - q) * tw;
        qs += (float2(noise(q / 40.0 + t * 0.8), noise(q / 40.0 + 9.0 - t * 0.7)) - 0.5) * 3.0 * tw;
    }

    // The water: slow swell (wave crests bunch up toward the far shore) and spreading rings.
    float ww = waterWeight(q);
    float2 rip = 0;
    if (ww > 0.0) {
        float near = saturate((q.y - kWaterTop) / 240.0);
        float phase = 3200.0 / (q.y - kWaterTop + 25.0);
        qs.x += ww * near * 5.0 * sin(phase - t * 1.1 + sin(q.x / 90.0 + t * 0.4) * 1.5);
        qs.y += ww * near * 2.0 * sin(phase * 0.7 - t * 0.9 + q.x / 140.0);
        rip = ripples(q, t) * ww;
        qs.y += rip.y * 3.0 * (0.3 + near);
    }

    float3 col = picture(qs);
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // Blossoms pulse with light in slow waves; reflections glint on the ripples.
    float bloom = smoothstep(0.25, 0.6, lum) * tw;
    col += col * bloom * 0.3 * (0.5 + 0.5 * sin(t * 0.8 + noise(q / 90.0) * 6.28));
    col += float3(1.0, 0.3, 0.6) * rip.x * (0.06 + lum * 0.6);
    float2 cell = floor(q / 5.0);
    float glint = pow(0.5 + 0.5 * sin(t * (1.5 + 2.0 * hash21(cell)) + hash21(cell + 3.0) * 40.0), 30.0);
    glint *= smoothstep(0.45, 0.1, length(frac(q / 5.0) - 0.5));  // a round point, not the whole cell
    col += float3(1.0, 0.6, 0.8) * glint * smoothstep(0.35, 0.7, lum) * ww * 0.6;

    // Neon petals: far ones behind the tree, nearer in front; each vanishes on reaching the water,
    // and the nearer ones show in it upside down, rippling, as they come close.
    FallStyle st = (FallStyle)0;
    st.kind = 0;
    st.base = float3(1.0, 0.1, 0.42);
    st.tip = float3(1.0, 0.42, 0.68);
    st.back = float3(0.9, 0.28, 0.55);
    st.through = float3(1.0, 0.25, 0.55);
    st.glow = 0.5;
    st.windX = -0.45;
    st.rightBias = 1.0;
    float3 ambient = float3(1.0, 0.2, 0.5) * 0.08;

    st.floorY = 1.0 - (kWaterTop + 10.0) / kImg.y;
    float4 far = fallingLayer(p, aspect, t, 0.1, 0.03, 0.011, 0.5, 11.0, 0.02, ambient, px, st);
    far *= 1.0 - smoothstep(0.1, 0.3, lum) * tw;
    col = col * (1.0 - far.a) + far.rgb * 0.55;

    st.floorY = 0.19;
    float4 mid = fallingLayer(p, aspect, t, 0.17, 0.05, 0.02, 0.8, 23.0, 0.0, ambient, px, st);
    if (p.y < st.floorY && ww > 0.0) {
        float2 pm = float2(p.x + (qs.x - q.x) * px * 1.5, 2.0 * st.floorY - p.y);
        float4 refl = fallingLayer(pm, aspect, t, 0.17, 0.05, 0.02, 0.8, 23.0, 0.01, ambient, px, st);
        col = col * (1.0 - refl.a * 0.3) + refl.rgb * 0.3;
    }
    col = col * (1.0 - mid.a) + mid.rgb * 0.85;

    st.floorY = 0.09;
    float4 nearP = fallingLayer(p, aspect, t, 0.3, 0.08, 0.036, 1.0, 37.0, 0.06, ambient, px, st);
    if (p.y < st.floorY && ww > 0.0) {
        float2 pm = float2(p.x + (qs.x - q.x) * px * 1.5, 2.0 * st.floorY - p.y);
        float4 refl = fallingLayer(pm, aspect, t, 0.3, 0.08, 0.036, 1.0, 37.0, 0.07, ambient, px, st);
        col = col * (1.0 - refl.a * 0.3) + refl.rgb * 0.3;
    }
    col = col * (1.0 - nearP.a * 0.92) + nearP.rgb * 0.92;
    return float4(col, 1.0);
}
