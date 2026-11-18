// Ghost ship: a ragged galleon at night on a dark sea. It rocks and pitches on the swell, its torn
// sails and pennants flutter in the wind, the lanterns flicker, fog rolls round the hull and drifts
// low across the water, and the waves roll with the lantern light shimmering on them.
// texture: assets/ghostship.jpg
// texture1: assets/ghostship_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kPivot = float2(1260.0, 700.0);   // the ship rocks about its waterline here
static const float kSea = 706.0;                      // the sea's surface starts here

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = the ship (rocks), g = fog (flows), b = sails and pennants (flutter).
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return parts(q).g; }
#include "fx.hlsli"

float lanternLight(float3 c) { return saturate(((c.r - c.b) / max(c.r, 0.02) - 0.45) * 3.0) * smoothstep(0.35, 0.8, c.r); }

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // The ship rolls and heaves on the swell (the masts swing more than the hull).
    float roll = radians(1.15 * sin(t * 0.55) + 0.3 * sin(t * 1.3 + 1.0));
    float heave = 4.0 * sin(t * 0.55 + 1.2);
    float shipW = parts(q).r;
    float2 qs = lerp(q, kPivot + rot(q - kPivot - float2(0.0, heave), -roll), shipW);

    // Sails and pennants flutter: ripples run through the cloth with the wind, strongest at the
    // pennants and the torn edges.
    float cloth = parts(qs).b;
    if (cloth > 0.01) {
        float pennant = smoothstep(150.0, 60.0, qs.y);
        float2 w = qs / 16.0 + float2(-t * 1.6, t * 0.3);
        float2 flap = float2(noise(w), noise(w + 5.3)) - 0.5;
        qs += flap * (2.4 + 5.0 * pennant) * cloth;
        qs.y += sin(qs.x / 14.0 - t * 5.0) * 2.5 * pennant * cloth;
    }

    // The sea rolls: waves run across, larger and slower close up.
    float sea = smoothstep(kSea - 4.0, kSea + 10.0, q.y);
    if (sea > 0.0) {
        float depth = saturate((q.y - kSea) / 235.0);
        float2 w = float2(q.x / (40.0 + 160.0 * depth), (q.y - kSea) / (6.0 + 28.0 * depth));
        float swell = sin(q.x / (80.0 + 240.0 * depth) - t * (0.9 - 0.3 * depth) + (q.y - kSea) / (9.0 + 36.0 * depth));
        qs.x += (noise(w + float2(t * 0.4, t * 0.12)) - 0.5) * (4.0 + 14.0 * depth) * sea;
        qs.y += ((noise(w * 1.3 + float2(-t * 0.3, 7.0)) - 0.5) * (2.0 + 6.0 * depth) + swell * (1.0 + 4.0 * depth)) * sea;
    }

    float3 col = parts(q).g > 0.001 && shipW < 0.5 ? streamSmoke(qs, t, float2(-10.0, -2.0)) : picture(qs);

    // The lanterns flicker, each in its own rhythm, and glow.
    float lamp = lanternLight(col);
    float2 cell = floor(qs / 45.0);
    float flicker = 0.75 + 0.35 * noise(float2(t * 7.0, hash21(cell) * 50.0)) + 0.15 * sin(t * 13.0 + hash21(cell + 1.0) * 20.0);
    col += col * lamp * (flicker - 0.85) * 1.6;
    if (shipW > 0.5 && q.y > 420.0) {
        float halo = 0.0;
        [unroll] for (int i = 0; i < 8; i++) {
            float a = i * 0.785;
            halo += lanternLight(picture(qs + float2(cos(a), sin(a)) * 12.0));
        }
        col += float3(1.0, 0.55, 0.2) * halo / 8.0 * 0.12 * flicker;
    }

    // The lantern light on the waves shimmers and flickers with them.
    float warmth = saturate((col.r - col.b) * 3.0);
    float glitter = noise(float2(q.x / 5.0, (q.y + t * 22.0) / 3.0));
    col += col * sea * warmth * ((glitter - 0.4) * 1.4 + (flicker - 0.85) * 0.8);

    // Fog drifting low across the water and round the hull.
    float band = smoothstep(560.0, 650.0, q.y) * smoothstep(800.0, 720.0, q.y) * smoothstep(760.0, 880.0, q.x);
    if (band > 0.01) {
        float d = smokeDensity(q, t, float2(-14.0, 0.0), 150.0) * band;
        col += float3(0.17, 0.17, 0.18) * d;
    }
    return float4(col, 1.0);
}
