// Guitar: a black electric guitar edged in blue light. Every few seconds its strings are strummed and
// vibrate, blurring widest in the middle and dying away; the blue light runs round the edge of the
// body and pulses, a sheen slides over the gloss, and the chrome catches sharp glints.
// texture: assets/guitar.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);     // picture pixels the positions below use
static const float2 kBridge = float2(1235.0, 600.0);  // the strings, from where they're anchored...
static const float2 kNut = float2(1520.0, 45.0);      // ...to the nut
static const float2 kBody = float2(1230.0, 640.0);    // middle of the body
static const float kStrum = 5.5;                      // seconds between strums

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float blueness(float3 c) { return saturate((c.b - max(c.r, c.g * 0.95)) * 3.0) * smoothstep(0.15, 0.5, c.b); }
float chrome(float3 c) {
    float mx = max(c.r, max(c.g, c.b));
    return smoothstep(0.35, 0.7, mx) * (1.0 - smoothstep(0.15, 0.35, (mx - min(c.r, min(c.g, c.b))) / max(mx, 0.02)));
}

// Sharp four-pointed glints that flash on bright chrome.
float3 glints(float2 q, float t, float cell, float seed) {
    float3 col = 0;
    float2 base = floor(q / cell);
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 id = base + float2(i, j);
        float2 at = (id + 0.2 + 0.6 * float2(hash21(id + seed), hash21(id + seed + 1.0))) * cell;
        float flash = pow(saturate(sin(t * (0.4 + 0.5 * hash21(id + seed + 2.0)) + hash21(id + seed + 3.0) * 30.0)), 50.0);
        if (flash < 0.01) continue;
        float c = chrome(picture(at));
        if (c <= 0.0) continue;
        float2 d = q - at;
        float star = exp(-length(d) / 1.5) + (exp(-abs(d.y) / 0.6) * exp(-abs(d.x) / 10.0) + exp(-abs(d.x) / 0.6) * exp(-abs(d.y) / 10.0)) * 0.7;
        col += float3(0.85, 0.92, 1.0) * star * flash * c;
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

    // The strings: where q is along them (0 at the bridge, 1 at the nut) and across them.
    float2 sd = kNut - kBridge;
    float len = length(sd);
    float2 su = sd / len, sn = float2(-su.y, su.x);
    float u = dot(q - kBridge, su) / len;
    float across = dot(q - kBridge, sn);
    float halfWidth = lerp(68.0, 24.0, saturate(u));  // the strings fan out toward the bridge
    float band = smoothstep(halfWidth + 6.0, halfWidth, abs(across)) * smoothstep(-0.02, 0.03, u) * smoothstep(1.0, 0.95, u);

    // A strum sweeps across the strings; each then vibrates, widest in the middle, dying away.
    float sinceStrum = frac(t / kStrum) * kStrum - (across / halfWidth + 1.0) * 0.04;
    float ring = sinceStrum > 0.0 ? exp(-sinceStrum * 1.4) : 0.0;
    float amp = 3.2 * ring * sin(3.1416 * saturate(u)) * band;

    float3 col = picture(q);
    if (amp > 0.05) {
        // Only the strings move: they're thin bright lines, so the darker of the pixels just either
        // side is what's behind them (pickups, frets, wood). The strings alone blur across their
        // width, as a vibrating string does to the eye.
        float3 strings = 0;
        [unroll] for (int k = -3; k <= 3; k++) {
            float2 at = q + sn * (k / 3.0) * amp;
            float3 c = picture(at);
            strings += c - min(picture(at - sn * 2.2), picture(at + sn * 2.2));
        }
        float3 behind = min(picture(q - sn * 2.2), picture(q + sn * 2.2));
        col = lerp(col, behind + strings / 7.0 * 1.15, band);
    }

    // The blue light runs round the edge of the body, and pulses.
    float2 db = q - kBody;
    float ang = atan2(db.y, db.x);
    float run = pow(0.5 + 0.5 * sin(ang * 2.0 - t * 1.6), 5.0) + 0.6 * pow(0.5 + 0.5 * sin(ang * 3.0 + t * 1.1 + 1.0), 8.0);
    float blue = blueness(col);
    col += col * blue * (1.4 * run + 0.35 * sin(t * 0.9));

    // A sheen slides slowly over the gloss and the chrome.
    float s = dot(q, normalize(float2(0.55, 0.83)));
    float sheen = exp(-pow((s - lerp(500.0, 1700.0, frac(t / 8.0))) / 60.0, 2.0));
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    col += (col * 1.2 + 0.03) * sheen * smoothstep(0.12, 0.45, lum) * 0.8;

    if (q.x > 950.0) col += glints(q, t, 24.0, 1.0);
    return float4(col, 1.0);
}
