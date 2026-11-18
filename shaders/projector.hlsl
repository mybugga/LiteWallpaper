// Film projector: an old film projector running in the dark. Both reels turn (the small one faster,
// as film winds at the same speed onto a smaller hub), the film runs down off the reels into the
// gate, the beam flickers frame by frame with the changing picture, dust swirls slowly in the beam,
// and the lens glows.
// texture: assets/projector.jpg
// texture1: assets/projector_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);  // picture pixels the positions below use
// Each reel: the centre of its face, how far its rim reaches left, right, up and down from there
// (the reels are seen at an angle), and the axle bolt sticking out of it (that doesn't turn).
static const float2 kBig = float2(1396.0, 224.0);
static const float4 kBigR = float4(124.0, 157.0, 221.0, 206.0);
static const float2 kBigBolt = float2(1377.0, 222.0);
static const float2 kSmall = float2(1130.0, 265.0);
static const float4 kSmallR = float4(65.0, 70.0, 120.0, 132.0);
static const float2 kSmallBolt = float2(1111.0, 272.0);
static const float2 kLens = float2(1128.0, 505.0);
static const float2 kApex = float2(1108.0, 505.0);   // where the beam starts

// The texture holds the picture (top 1440 rows) and, below it, a clean copy of the big reel with
// the film strip and bracket in front of it filled in, for the turning reel to show.
static const float kTexH = 2114.0;
static const float2 kReelCrop = float2(1260.0, 0.0);  // picture px of the clean copy's corner
float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg * float2(1.0, 1440.0 / kTexH), 0).rgb; }
float3 cleanReel(float2 q) {
    float2 uv = ((q - kReelCrop) * (2560.0 / 1672.0) + float2(0.0, 1440.0)) / float2(2560.0, kTexH);
    return iChannel0.SampleLevel(iSampler, uv, 0).rgb;
}
// r = big reel face, g = small reel face, b = the beam.
float3 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

// A reel's face turned by `a`: points are taken to the flat face (undoing the angle it's seen at),
// turned, and brought back.
float2 turnFace(float2 q, float2 c, float4 radii, float a) {
    float2 v = q - c;
    float2 n = float2(v.x / (v.x < 0.0 ? radii.x : radii.y), v.y / (v.y < 0.0 ? radii.z : radii.w));
    n = rot(n, -a);
    return c + float2(n.x * (n.x < 0.0 ? radii.x : radii.y), n.y * (n.y < 0.0 ? radii.z : radii.w));
}

// The turning reel's picture without its axle bolt (which doesn't turn): inside the bolt, the hub
// plate just outside it is shown instead.
float2 outsideBolt(float2 src, float2 bolt, float r) {
    float2 v = src - bolt;
    float d = length(v);
    return d < r ? bolt + v / max(d, 0.001) * (2.0 * r - d + 2.0) : src;
}

// Film running along a strip from a to b: two copies slide along it, each fading out as the other
// fades in, so it runs on and on.
float3 runningFilm(float2 q, float2 a, float2 b, float t, float speed) {
    float2 d = normalize(b - a);
    const float period = 0.6;
    float ph1 = frac(t / period), ph2 = frac(t / period + 0.5);
    float w1 = 1.0 - abs(2.0 * ph1 - 1.0);
    return picture(q - d * speed * period * (ph1 - 0.5)) * w1 + picture(q - d * speed * period * (ph2 - 0.5)) * (1.0 - w1);
}
float stripWeight(float2 q, float2 a, float2 b, float halfWidth) {
    float2 d = b - a;
    float s = saturate(dot(q - a, d) / dot(d, d));
    return smoothstep(halfWidth, halfWidth - 2.0, length(q - a - d * s)) * smoothstep(0.0, 0.06, s) * smoothstep(1.0, 0.94, s);
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 fx = parts(q);
    float3 col = picture(q);

    // The reels turn clockwise; the axle bolts stay put.
    if (fx.r > 0.001) {
        float2 src = outsideBolt(turnFace(q, kBig, kBigR, t * 0.55), kBigBolt, 15.0);
        col = lerp(col, cleanReel(src), fx.r * smoothstep(14.0, 17.0, length(q - kBigBolt)));
    }
    if (fx.g > 0.001) {
        float2 src = turnFace(q, kSmall, kSmallR, t * 1.1);
        col = lerp(col, picture(outsideBolt(src, kSmallBolt, 12.0)), fx.g * smoothstep(11.0, 14.0, length(q - kSmallBolt)));
    }

    // The film runs down off the reels.
    float sA = stripWeight(q, float2(1382.0, 258.0), float2(1333.0, 445.0), 8.0);
    if (sA > 0.0) col = lerp(col, runningFilm(q, float2(1382.0, 258.0), float2(1333.0, 445.0), t, 45.0), sA);
    float sB = stripWeight(q, float2(1212.0, 185.0), float2(1236.0, 400.0), 9.0) * (1.0 - fx.g);
    if (sB > 0.0) col = lerp(col, runningFilm(q, float2(1236.0, 400.0), float2(1212.0, 185.0), t, 45.0), sB);

    // The beam flickers frame by frame (24 a second), its shafts shifting with the changing picture.
    float frame = floor(t * 24.0);
    float flick = 1.0 + 0.1 * (hash21(float2(frame, 1.0)) - 0.5) + 0.06 * sin(t * 0.9);
    float2 fromApex = q - kApex;
    float angle = atan2(fromApex.y, -fromApex.x);
    float shafts = 0.75 + 0.5 * noise(float2(angle * 26.0, floor(t * 6.0) * 3.1)) * (0.6 + 0.4 * noise(float2(angle * 9.0, t * 0.7)));
    col *= 1.0 + fx.b * ((flick - 1.0) * 1.6 + (shafts - 1.0) * 0.5);

    // Dust drifting and turning in the light.
    if (fx.b > 0.01) {
        float dust = motes(p, t, 0.035, 0.0011, 0.45, 3.0, px) + motes(p, t, 0.06, 0.0022, 0.35, 11.0, px) * 0.8 +
                     motes(p, t, 0.11, 0.0045, 0.2, 23.0, px) * 0.5;
        float lightHere = saturate(dot(picture(q), float3(0.3, 0.5, 0.2)) * 4.0);
        col += float3(1.0, 0.86, 0.62) * dust * fx.b * (0.35 + lightHere) * 0.55 * flick;
    }

    // The lens glows, flickering with the beam.
    float rl = length(q - kLens);
    col += float3(1.0, 0.85, 0.6) * (exp(-rl / 16.0) * 0.18 + exp(-rl / 70.0) * 0.06) * flick;
    return float4(col, 1.0);
}
