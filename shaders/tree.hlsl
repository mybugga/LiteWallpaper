// Tree: a broad green tree on black. Its crown sways from the trunk while gusts roll across it, the
// leaves flutter and catch glints of sun, patches of sunlight drift over the canopy, and now and
// then a leaf (sometimes a yellowing one) comes loose and tumbles to the ground.
// texture: assets/tree.jpg
// scale: 1
#include "space.hlsli"
#include "falling.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kRoot = float2(820.0, 900.0);   // base of the trunk: the crown sways about it
static const float kCrownBottom = 690.0;            // lowest leaves

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // Sway: the whole tree leans about its roots, more the higher up; the trunk's foot stays put.
    float bendW = pow(smoothstep(880.0, 300.0, q.y), 1.3);
    float gustT = 0.5 + 0.5 * sin(t * 0.17);  // the wind comes and goes
    float angle = radians((0.35 * sin(t * 0.45) + 0.2 * sin(t * 1.1 + 1.3)) * (0.6 + 0.8 * gustT));
    float2 qs = q + (kRoot + rot(q - kRoot, angle) - q) * bendW;

    // Gusts roll across the crown, and the leaves flutter.
    float crownW = smoothstep(kCrownBottom + 30.0, kCrownBottom - 60.0, q.y);
    float gust = fbm3(float2(q.x / 260.0 - t * 0.35, q.y / 260.0)) - 0.5;
    qs.x += gust * 9.0 * crownW * (0.6 + 0.8 * gustT);
    qs += (float2(noise(q / 9.0 + t * 2.4), noise(q / 9.0 + 5.3 - t * 2.1)) - 0.5) * 1.6 * crownW;

    float3 col = picture(qs);
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float leafy = saturate((col.g - max(col.r, col.b)) * 5.0) * smoothstep(0.04, 0.2, lum) * crownW;

    // Sunlight drifting over the leaves, and glints where leaves turn to the sun.
    float sun = fbm3(q / 190.0 + float2(t * 0.04, t * 0.015));
    col *= 1.0 + 0.35 * (sun - 0.5) * leafy;
    float2 cell = floor(q / 5.0);
    float glint = pow(0.5 + 0.5 * sin(t * (1.0 + 2.5 * hash21(cell)) + hash21(cell + 3.0) * 40.0), 28.0);
    glint *= smoothstep(0.45, 0.1, length(frac(q / 5.0) - 0.5));
    col += float3(0.9, 1.0, 0.7) * glint * smoothstep(0.3, 0.6, lum) * leafy * 0.5;

    // Falling leaves, only under the crown: far ones pass behind the tree.
    FallStyle st = (FallStyle)0;
    st.kind = 1;
    st.base = float3(0.14, 0.33, 0.06);
    st.tip = float3(0.36, 0.6, 0.12);
    st.back = float3(0.36, 0.5, 0.24);
    st.through = float3(0.6, 0.85, 0.2);
    st.alt = float3(0.78, 0.66, 0.16);
    st.windX = -0.25;
    st.rightBias = 0.0;
    st.floorY = 1.0 - 905.0 / kImg.y;
    float region = smoothstep(0.1, 0.18, p.x / aspect) * smoothstep(0.9, 0.82, p.x / aspect) * smoothstep(0.98, 0.88, p.y);
    float3 sunlit = float3(0.25, 0.22, 0.12);  // warm light on them

    float4 far = fallingLayer(p, aspect, t, 0.11, 0.04, 0.011, 0.35, 11.0, 0.02, sunlit * 0.3, px, st) * region;
    far *= 1.0 - smoothstep(0.08, 0.25, lum);
    col = col * (1.0 - far.a) + far.rgb * 0.6;
    float4 mid = fallingLayer(p, aspect, t, 0.19, 0.065, 0.02, 0.35, 23.0, 0.0, sunlit * 0.5, px, st) * region;
    col = col * (1.0 - mid.a) + mid.rgb;
    float4 nearP = fallingLayer(p, aspect, t, 0.33, 0.1, 0.035, 0.25, 37.0, 0.07, sunlit * 0.5, px, st) * region;
    col = col * (1.0 - nearP.a * 0.92) + nearP.rgb * 0.92;
    return float4(col, 1.0);
}
