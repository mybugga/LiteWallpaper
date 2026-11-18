// Pocket watch: an open skeleton pocket watch in warm light. Its red seconds hand sweeps round in
// five small beats a second, like a real mechanical watch, in time with the balance wheel swinging
// back and forth under its silver bridge; the mainspring barrel turns slowly, a glint slides across
// the glass, the engraving catches the light, and dust drifts in the warm glow.
// texture: assets/watch.jpg
// texture1: assets/watch_fx.png
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);       // picture pixels the positions below use
static const float2 kHub = float2(1156.0, 452.0);       // centre of the hands
static const float2 kBalance = float2(1150.0, 562.5);   // balance wheel
static const float2 kBarrel = float2(1224.0, 371.0);    // mainspring barrel
static const float kStartSeconds = 38.2;                 // where the photo's seconds hand pointed
static const float kBeat = 5.0;                          // beats a second (a 2.5 Hz balance)

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
// r = balance wheel (swings), g = barrel (turns).
float2 parts(float2 q) { return iChannel1.SampleLevel(iSampler, q / kImg, 0).rg; }
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

float balanceAngle(float t) { return 0.62 * sin(t * 6.2832 * kBeat * 0.5); }

// The balance wheel swings about its staff; the silver bridge over it stays put. Where the part of
// the wheel that should show is hidden under the bridge in the photo, take the wheel from a little
// further round instead. Three samples across the frame blur it at speed.
float3 balanceWheel(float2 q, float t, float3 here) {
    float m = parts(q).r;
    if (m <= 0.001) return here;
    float2 d = q - kBalance;
    float3 acc = 0;
    [unroll] for (int k = -1; k <= 1; k++) {
        float a = balanceAngle(t + k * 0.011);
        float2 src = kBalance + rot(d, -a);
        float3 c = picture(src);
        if (parts(src).r < 0.5) {
            float2 alt1 = kBalance + rot(d, -a + 0.55), alt2 = kBalance + rot(d, -a - 0.55);
            c = parts(alt1).r > 0.5 ? picture(alt1) : picture(alt2);
        }
        acc += c;
    }
    return lerp(here, acc / 3.0, m);
}

// The barrel turns slowly. Only its fine detail (teeth, screw, brushing) turns; the light on it
// stays where it is, as it would. Its shading is averaged from the barrel alone, never the minute
// hand lying across it; where the hand hides the part that should turn into view, the detail is
// taken from a little further round (the barrel is circular).
float3 barrelLow(float2 q) {
    float3 c = 0;
    float w = 0.0;
    [unroll] for (int i = 0; i < 7; i++) {
        float2 o = i == 0 ? float2(0.0, 0.0) : float2(cos(i * 1.0472), sin(i * 1.0472)) * 5.0;
        float g = parts(q + o).g;
        c += picture(q + o) * g;
        w += g;
    }
    return c / max(w, 0.001);
}
float3 barrel(float2 q, float t, float3 here) {
    float m = parts(q).g;
    if (m <= 0.001) return here;
    float a = -t * 0.05;
    float3 detail = 0;
    [unroll] for (int k = 0; k < 5; k++) {
        float off = k == 0 ? 0.0 : (k % 2 == 1 ? 0.45 : -0.45) * floor((k + 1) / 2);
        float2 src = kBarrel + rot(q - kBarrel, a + off);
        if (parts(src).g > 0.98) {
            detail = picture(src) - barrelLow(src);
            break;
        }
    }
    return lerp(here, barrelLow(q) + detail, m);
}

// The seconds hand at picture point q: x = coverage, y = lighting across it, z = shadow it casts.
float3 secondsHand(float2 q, float sec) {
    float th = sec / 60.0 * 6.2832;
    float2 u = float2(sin(th), -cos(th));  // towards the tip (picture y points down)
    float2 n = float2(cos(th), sin(th));
    float aa = 0.7;
    float3 r = 0;
    [unroll] for (int layer = 0; layer < 2; layer++) {
        float2 d = q - kHub - (layer == 1 ? float2(4.0, 5.0) : 0.0);  // layer 1: its shadow, offset from the light
        float along = dot(d, u), across = dot(d, n);
        float w = along >= 0.0 ? lerp(1.7, 0.6, saturate(along / 202.0))
                               : 1.5 + 3.0 * pow(sin(3.1416 * saturate(-along / 62.0)), 0.85);
        float ends = smoothstep(-62.5, -61.0, along) * smoothstep(203.0, 201.0, along);
        if (layer == 0) {
            r.x = smoothstep(w + aa, w - aa, abs(across)) * ends;
            r.y = across / max(w, 0.5);
        } else {
            r.z = smoothstep(w + 3.0, w - 1.0, abs(across)) * ends;
        }
    }
    return r;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    float3 col = picture(q);
    col = balanceWheel(q, t, col);
    col = barrel(q, t, col);
    float lum = dot(col, float3(0.3, 0.5, 0.2));

    // The seconds hand: beats in time with the balance, each a quick snap forward.
    float beats = t * kBeat;
    float sec = kStartSeconds + (floor(beats) + smoothstep(0.0, 0.18, frac(beats))) / kBeat;
    float rHub = length(q - kHub);
    if (rHub < 215.0) {
        float3 h = secondsHand(q, sec);
        col *= 1.0 - 0.45 * h.z;
        float2 lightDir = normalize(float2(-0.8, -1.0));
        float th = sec / 60.0 * 6.2832;
        float facing = h.y * dot(float2(cos(th), sin(th)), lightDir);
        float3 red = float3(0.62, 0.03, 0.04) * (0.7 + 0.6 * saturate(0.5 + 0.5 * facing));
        red += float3(1.0, 0.45, 0.35) * pow(saturate(1.0 - abs(h.y - 0.35 * sign(facing + 0.001))), 6.0) * 0.25;
        col = lerp(col, red, h.x);

        // Its cap at the centre: a red dome with a pin.
        float2 dc = (q - kHub) / 10.5;
        float rc = length(dc);
        if (rc < 1.15) {
            float3 nrm = float3(dc, sqrt(saturate(1.0 - rc * rc)));
            float3 L = normalize(float3(-0.55, -0.65, 0.6));
            float lit = saturate(dot(nrm, L));
            float3 cap = float3(0.55, 0.02, 0.03) * (0.45 + 0.9 * lit) + pow(saturate(dot(reflect(-L, nrm), float3(0, 0, 1))), 18.0) * 0.5;
            float pin = smoothstep(0.42, 0.36, rc);
            cap = lerp(cap, float3(0.85, 0.74, 0.55) * (0.6 + 0.6 * lit) + pow(lit, 12.0) * 0.4, pin);
            cap *= 1.0 - 0.5 * smoothstep(0.8, 1.0, rc);  // darker rim
            col = lerp(col, cap, smoothstep(1.02, 0.96, rc));
            col *= 1.0 - 0.35 * smoothstep(1.15, 1.0, rc) * step(1.0, rc);  // a little shadow round it
        }
    }

    // A glint slides across the glass every eleven seconds.
    if (rHub < 214.0) {
        float s = dot(q - kHub, normalize(float2(1.0, -1.5)));
        float sweep = lerp(-260.0, 260.0, frac(t / 11.0));
        float glint = exp(-pow((s - sweep) / 22.0, 2.0)) * smoothstep(214.0, 190.0, rHub);
        col += float3(1.0, 0.92, 0.8) * glint * 0.09 + col * glint * 0.25;
    }

    // The engraving and edges catch the light now and then.
    col += float3(1.0, 0.85, 0.6) * twinkle(q, t, 4.0, 40.0) * smoothstep(0.5, 0.85, lum) * smoothstep(222.0, 240.0, rHub) * 0.8;

    // Warm light that flickers a touch, like a candle, and dust drifting in it.
    col *= 1.0 + 0.035 * (noise(float2(t * 1.7, 2.0)) - 0.5) + 0.02 * sin(t * 0.6);
    float2 sp = float2(p.x / aspect, p.y);
    float light = smoothstep(1.05, 0.25, length((sp - float2(0.62, 0.55)) * float2(1.6, 1.0)));
    float dust = motes(p, t, 0.07, 0.0016, 0.35, 3.0, px) + motes(p, t, 0.13, 0.0045, 0.25, 11.0, px) * 0.6;
    col += float3(1.0, 0.72, 0.4) * dust * light * 0.35;
    return float4(col, 1.0);
}
