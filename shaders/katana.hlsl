// Katana: a katana hangs in the dark while cherry blossom petals drift down around it, tumbling and
// swaying, some behind the blade and some in front, near ones soft as if out of focus and lit pink
// as they pass the blade's glow. Every few seconds a gleam runs down the blade, its glow breathes,
// and the sakura charm swings on its cord. Each petal is a small 3D object: a cupped sakura petal
// that tumbles freely, shaded with soft light, light glowing through it and a faint sheen.
// texture: assets/katana.jpg
// scale: 1
#include "space.hlsli"
#include "falling.hlsli"

static const float2 kImg = float2(1672.0, 941.0);   // picture pixels the positions below use
static const float2 kBladeA = float2(1432.0, 300.0);  // blade, just below the guard
static const float2 kBladeB = float2(1165.0, 902.0);  // blade tip
static const float2 kGlow = float2(1360.0, 455.0);    // where the blade glows pink
static const float2 kPivot = float2(1556.0, 38.0);    // where the charm's cord hangs from

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// The charm and tassel hang to the right of the handle; swing them about the cord's top.
float2 swingCharm(float2 q, float t) {
    float handleEdge = max(1540.0 - (q.y - 30.0) * 0.45 + 12.0, 1515.0);
    float region = step(handleEdge, q.x) * step(60.0, q.y) * step(q.y, 365.0);
    float angle = radians(2.6 * sin(t * 1.7) + 0.9 * sin(t * 0.63 + 1.0));
    return lerp(q, kPivot + rot(q - kPivot, -angle), region);
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;

    // Fill the screen with the picture (cropping if needed).
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 col = picture(swingCharm(q, t));
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // A gleam runs down the blade every seven seconds.
    float2 ab = kBladeB - kBladeA;
    float s = saturate(dot(q - kBladeA, ab) / dot(ab, ab));
    float across = length(q - kBladeA - ab * s);
    float onBlade = smoothstep(26.0, 10.0, across) * smoothstep(0.1, 0.35, lum);
    float sweep = frac(t / 7.0) * 1.6 - 0.3;
    float gleam = exp(-pow((s - sweep) / 0.035, 2.0));
    col += (col + 0.35) * gleam * onBlade * 1.3;
    float2 spark = kBladeA + ab * saturate(sweep) - float2(6.0, 0.0);
    float2 ds = (q - spark) / kImg.y;
    float sparkle = (exp(-length(ds) / 0.004) + (exp(-abs(ds.y) / 0.0012) * exp(-abs(ds.x) / 0.03) +
                    exp(-abs(ds.x) / 0.0012) * exp(-abs(ds.y) / 0.03)) * 0.5) * step(0.0, sweep) * step(sweep, 1.0);
    col += float3(1.0, 0.85, 0.95) * sparkle * 0.8;

    // The pink glow on the blade breathes.
    float rg = length(q - kGlow) / kImg.y;
    col += float3(1.0, 0.3, 0.65) * (exp(-rg / 0.012) * 0.25 + exp(-rg / 0.05) * 0.08) * (0.5 + 0.5 * sin(t * 0.9));

    // Petals: the far ones pass behind the sword, the nearer ones in front of it. Those passing the
    // blade's glow pick up its pink light.
    float3 glowLight = float3(1.0, 0.35, 0.65) * 0.6 * exp(-length(q - kGlow) / 170.0) * (0.6 + 0.4 * sin(t * 0.9));
    FallStyle petals = sakuraPetals();
    float4 far = fallingLayer(p, aspect, t, 0.1, 0.035, 0.011, 0.45, 11.0, 0.03, glowLight, px, petals);
    far *= 1.0 - smoothstep(0.08, 0.25, lum);
    col = col * (1.0 - far.a) + far.rgb * 0.45;
    float4 mid = fallingLayer(p, aspect, t, 0.17, 0.06, 0.022, 0.8, 23.0, 0.0, glowLight, px, petals);
    col = col * (1.0 - mid.a) + mid.rgb * 0.85;
    float4 nearP = fallingLayer(p, aspect, t, 0.3, 0.1, 0.042, 1.0, 37.0, 0.08, glowLight, px, petals);  // out of focus
    col = col * (1.0 - nearP.a * 0.92) + nearP.rgb * 0.92;
    return float4(col, 1.0);
}
