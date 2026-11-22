// Ghost orchid: pale ghost orchids growing from a mossy branch, with three luna moths resting
// round them. The moths slowly open and close their wings, the orchids sway on their stems, the
// water drops on a petal tip and a root swell and glint, and the flowers' soft glow breathes.
// texture: assets/ghost_orchid.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

static const float2 kBase = float2(330.0, 1330.0);  // picture pixels: where the plant grows from the moss

// A resting moth's wings slowly opening and closing: points on its wings move towards its body
// (seen from above, a wing tilting up looks narrower). `axis` is the direction its body points.
float2 flap(float2 q, float2 body, float2 axis, float2 reach, float amount) {
    float2 n = float2(-axis.y, axis.x);
    float along = dot(q - body, axis), across = dot(q - body, n);
    float wings = smoothstep(18.0, 45.0, abs(across)) * exp(-pow(length(float2(along / reach.y, across / reach.x)), 4.0));
    return q + n * across * amount * wings;
}

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = squarePoint(fragCoord, 0.95);

    // The moths, each at its own slow pace.
    q = flap(q, float2(1590.0, 300.0), float2(0.0, 1.0), float2(440.0, 560.0), 0.075 * (0.5 - 0.5 * cos(t * 1.6)));
    q = flap(q, float2(610.0, 330.0), normalize(float2(-0.5, 1.0)), float2(170.0, 170.0), 0.08 * (0.5 - 0.5 * cos(t * 1.9 + 2.0)));
    q = flap(q, float2(1320.0, 1290.0), normalize(float2(1.0, 0.55)), float2(380.0, 420.0), 0.07 * (0.5 - 0.5 * cos(t * 1.4 + 4.0)));

    // The orchids sway on their stems, more the further out from the moss.
    float reach = saturate((length(q - kBase) - 150.0) / 900.0);
    float plant = smoothstep(1350.0, 1150.0, q.x) * smoothstep(120.0, 260.0, q.y) * smoothstep(1500.0, 1300.0, q.y);
    q.x += (sin(t * 0.55 + q.y / 500.0) * 7.0 + sin(t * 1.1 + q.x / 300.0) * 2.0) * reach * reach * plant;
    q.y += sin(t * 0.45 + q.x / 400.0) * 3.0 * reach * plant;

    // The drops on the petal tip and the root tip swell as they gather water.
    float2 drops[2] = { float2(1240.0, 1395.0), float2(350.0, 1940.0) };
    [unroll] for (int k = 0; k < 2; k++) {
        float2 d = q - drops[k];
        float w = smoothstep(36.0, 14.0, length(d));
        q = lerp(q, drops[k] + d / (1.0 + 0.1 * (0.5 + 0.5 * sin(t * (0.8 + 0.3 * k)))), w);
    }

    float3 col = picture(q);
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // The flowers' and wings' soft glow breathes.
    float pale = smoothstep(0.45, 0.85, lum);
    col *= 1.0 + pale * 0.08 * sin(t * 0.6 + q.x / 700.0);
    col += float3(0.75, 0.7, 1.0) * exp(-length(q - float2(950.0, 700.0)) / 600.0) * (0.04 + 0.03 * sin(t * 0.6)) * smoothstep(0.02, 0.2, lum);

    // Glints on the drops, the dew on the wings and the glassy roots.
    float bright = smoothstep(0.65, 0.95, lum);
    col += float3(0.95, 0.95, 1.0) * twinkle(q, t, 9.0, 32.0) * bright * 0.7;
    [unroll] for (int j = 0; j < 2; j++) {
        float r = length(q - drops[j] - float2(-5.0, -6.0));
        col += float3(1.0, 1.0, 1.0) * exp(-r * r / 30.0) * (0.35 + 0.35 * sin(t * 1.7 + j * 2.0));
    }
    return float4(col, 1.0);
}
