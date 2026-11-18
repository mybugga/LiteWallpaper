// Shared by the planet_* wallpapers: brings a still picture of a ringed planet to life. The camera
// floats, light streams round the rings (faster on the inside, like real orbits) with glints riding
// along, the planet's glowing cracks pulse and its rim breathes, the flare on its edge pulses with
// turning rays, nebula clouds shimmer, and bright crystals sparkle.
//
// Before including, a wallpaper defines its picture's geometry in picture pixels (kImg):
//   kPlanet (cx, cy, radius), kRing (cx, cy, angle in degrees, outer radius), kRingRatio (minor/major),
//   kFlare (x, y), kFlareColor, kRingSpeed, and optionally kCorona (see below).
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);

// Fills the screen with the picture (cropping as needed), floating very slowly. Returns the
// picture pixel under screen point p, given in screen-height units.
float2 pictureCoord(float2 p, float aspect, float t) {
    float imgAspect = kImg.x / kImg.y;
    float2 screenUV = float2(p.x / aspect, 1.0 - p.y);
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float zoom = 1.045 + 0.025 * sin(t * 0.013);
    float2 drift = float2(sin(t * 0.0071), cos(t * 0.0093)) * 0.006;
    float2 uv = 0.5 + (screenUV - 0.5) * fit / zoom + drift;
    return uv * kImg;
}

float3 picture(float2 px) { return iChannel0.SampleLevel(iSampler, px / kImg, 0).rgb; }

// Ring-plane position (radius in units of the ring's outer radius, angle) to picture pixels.
float2 ringToPicture(float r, float a, float ratio) {
    float2 v = float2(cos(a), sin(a) * ratio) * r * kRing.w;
    return kRing.xy + rot(v, radians(kRing.z));
}

// True when something at ring angle a is on the far side and pixel q is covered by the planet.
float hiddenByPlanet(float2 q, float a) {
    float behind = smoothstep(0.05, -0.05, sin(a));
    return behind * smoothstep(kPlanet.z * 1.02, kPlanet.z * 0.96, length(q - kPlanet.xy));
}

// Debris orbiting in the ring plane: glowing chunks with short trails, inner ones faster (Kepler).
// The ring plane is cut into thin circular bands and each band into cells that turn with it; a
// cell may hold one chunk. Checking the neighbouring bands and cells covers trails and glow.
float3 orbitingDebris(float2 q, float t, float spin) {
    float2 rq = rot(q - kRing.xy, -radians(kRing.z));
    rq.y /= kRingRatio;
    float2 rn = rq / kRing.w;
    float r = length(rn);
    if (r < 0.33 || r > 1.08) return 0;
    float theta = atan2(rn.y, rn.x);
    const float r0 = 0.35, r1 = 1.05, bands = 30.0;
    float fb = (r - r0) / (r1 - r0) * bands;
    float3 col = 0;
    [unroll] for (int db = -1; db <= 1; db++) {
        float b = floor(fb) + db;
        if (b < 0.0 || b >= bands) continue;
        float rb = r0 + (b + 0.5) / bands * (r1 - r0);
        float omega = spin * pow(rb, -1.5);
        float cells = floor(6.2832 * rb / 0.03);
        float local = (theta - omega * t) / 6.2832 * cells;
        [unroll] for (int dk = -1; dk <= 1; dk++) {
            float k = floor(local) + dk;
            float kw = k - cells * floor(k / cells);  // wrap round the circle
            float2 id = float2(b, kw);
            float h = hash21(id + 7.0);
            if (h > 0.16) continue;
            float rp = rb + (hash21(id + 1.0) - 0.5) * (r1 - r0) / bands * 0.8;
            float ap = (k + 0.2 + 0.6 * hash21(id + 2.0)) / cells * 6.2832 + omega * t;
            float2 at = ringToPicture(rp, ap, kRingRatio);
            float2 tangent = normalize(ringToPicture(rp, ap + 0.01, kRingRatio) - at);
            float2 d = q - at;
            float along = dot(d, -tangent), across = dot(d, float2(-tangent.y, tangent.x));
            float size = 0.7 + 1.6 * pow(hash21(id + 3.0), 4.0);
            float trail = min(omega * rp * kRing.w * 0.12, 9.0);  // short enough to stay in its cell
            float shape = exp(-across * across / (2.0 * size * size)) *
                          (along < 0.0 ? exp(-along * along / (2.0 * size * size)) : exp(-along / max(trail, size)));
            float3 tint = lerp(kFlareColor, float3(1.0, 1.0, 1.0), hash21(id + 4.0) * 0.7);
            float bright = 0.25 + 0.75 * pow(hash21(id + 5.0), 2.0);
            col += tint * shape * bright * (1.0 - hiddenByPlanet(q, ap));
        }
    }
    return col;
}

// A small moon on its own tilted orbit, lit from the flare's side, passing behind the planet.
float4 orbitingMoon(float2 q, float t) {
    float a = t * 0.09 + 2.0;
    float orbit = kPlanet.z * 1.9;
    float2 v = float2(cos(a), sin(a) * 0.42) * orbit;
    float2 at = kPlanet.xy + rot(v, radians(kRing.z - 6.0));
    float radius = kPlanet.z * (0.065 + 0.012 * sin(a));  // a touch larger when nearer
    float2 d = (q - at) / radius;
    float r = length(d);
    if (r > 1.6) return 0;
    float3 n = float3(d, sqrt(saturate(1.0 - r * r)));
    float2 toLight = normalize(kFlare - kPlanet.xy);
    float3 L = normalize(float3(toLight, 0.7));
    float surface = 0.6 + 0.4 * fbm3(d * 2.5 + 3.0) - 0.2 * smoothstep(0.6, 0.75, noise(d * 5.0 + 1.0));
    float3 col = lerp(float3(0.55, 0.56, 0.6), kFlareColor * 0.6, 0.2) * surface * (pow(saturate(dot(n, L)), 1.3) + 0.02);
    col += kFlareColor * pow(1.0 - n.z, 3.0) * saturate(dot(n.xy, toLight) + 0.4) * 0.5;  // rim light
    float cover = smoothstep(1.0 + 1.5 / radius, 1.0 - 1.5 / radius, r);
    float hidden = hiddenByPlanet(q, a);
    return float4(col, cover) * (1.0 - hidden);
}


float3 animatePlanet(float2 p, float px, float t, float aspect) {
    float2 q = pictureCoord(p, aspect, t);
    float2 dp = q - kPlanet.xy;
    float onPlanet = smoothstep(kPlanet.z * 1.01, kPlanet.z * 0.97, length(dp));
    float2 rq = rot(q - kRing.xy, -radians(kRing.z));
    rq.y /= kRingRatio;
    float rr = length(rq) / kRing.w;
    float band = smoothstep(0.25, 0.35, rr) * smoothstep(1.15, 1.0, rr);

    float2 qs = q;
    float3 col = picture(qs);

    // Nebula clouds flow and boil: where the picture is coloured gas (not rock, planet or ring),
    // bend it with a slowly changing swirl.
    float l0 = dot(col, float3(0.3, 0.5, 0.2));
    float s0 = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));
    float cloud = smoothstep(0.18, 0.45, s0) * smoothstep(0.03, 0.2, l0) * (1.0 - onPlanet) * (1.0 - band);
    if (cloud > 0.001) {
        float2 swirl = (float2(fbm3(q / 140.0 + t * 0.06), fbm3(q / 140.0 + 7.3 - t * 0.05)) - 0.5) * 28.0;
        swirl += float2(sin(q.y / 90.0 + t * 0.4), cos(q.x / 110.0 - t * 0.35)) * 5.0;
        col = lerp(col, picture(qs + swirl), cloud);
    }
    float lum = dot(col, float3(0.3, 0.5, 0.2));
    float sat = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));

    // Rings: in the ring's own plane, light streams round; inner parts orbit faster.
    float spin = kRingSpeed * 1.8;
    float a = atan2(rq.y, rq.x) - t * spin * pow(max(rr, 0.2), -1.5);
    float2 ca = float2(cos(a), sin(a));
    float flow = fbm3(ca * 5.0 + float2(rr * 30.0, rr * 11.0));
    float glint = smoothstep(0.82, 0.97, noise(ca * 70.0 + rr * 260.0));
    float ringMask = band * smoothstep(0.12, 0.45, lum) * (1.0 - 0.6 * onPlanet);
    col *= 1.0 + 0.8 * (flow - 0.45) * ringMask;
    col += (col + 0.3) * glint * ringMask * 0.6;

    // Planet: glowing cracks pulse in slow waves; the rim of the atmosphere breathes.
    float veins = smoothstep(0.25, 0.6, sat) * smoothstep(0.15, 0.5, lum) * onPlanet;
    float pulse = 0.5 + 0.5 * sin(t * 1.1 + noise(q / 40.0) * 6.28 + noise(q / 140.0 + 9.0) * 6.28);
    col += col * veins * pulse * 0.45;
    float rim = exp(-abs(length(dp) - kPlanet.z) / (kPlanet.z * 0.025));
    col += kFlareColor * rim * (0.5 + 0.5 * sin(t * 0.7)) * 0.12;

    // Nebula clouds shimmer slowly.
    float neb = smoothstep(0.2, 0.5, sat) * smoothstep(0.03, 0.25, lum) * (1.0 - onPlanet) * (1.0 - band);
    col *= 1.0 + 0.55 * (fbm3(q / 170.0 + float2(t * 0.03, -t * 0.02)) - 0.5) * neb;

#ifdef HAS_CORONA
    // An eclipsed star's corona: its streamers flicker.
    float2 dc = q - kCorona.xy;
    float ac = atan2(dc.y, dc.x);
    float streamers = noise(float2(ac * 9.0 + t * 0.15, length(dc) / 60.0 - t * 0.3));
    float corona = smoothstep(0.2, 0.6, lum) * smoothstep(kCorona.z * 2.2, kCorona.z, length(dc)) * (1.0 - onPlanet);
    col *= 1.0 + 0.6 * (streamers - 0.45) * corona;
#endif

    // Bright crystals and rocks catch the light now and then.
    float2 cell = floor(q / 6.0);
    float tw = pow(0.5 + 0.5 * sin(t * (0.8 + 2.0 * hash21(cell)) + hash21(cell + 3.1) * 50.0), 24.0);
    tw *= smoothstep(0.45, 0.1, length(frac(q / 6.0) - 0.5));  // a round point, not the whole cell
    col += float3(1.0, 1.0, 1.0) * tw * smoothstep(0.72, 0.95, lum) * 0.5;

    // The flare on the planet's edge.
    float2 d = (q - kFlare) / kImg.y;
    float r = length(d);
    float pulseF = 0.8 + 0.2 * sin(t * 0.6) + 0.06 * sin(t * 2.1);
    float ang = atan2(d.y, d.x) + t * 0.04;
    float rays = pow(abs(cos(ang * 4.0)), 40.0) * exp(-r / 0.05) + pow(abs(cos(ang * 3.0 + 1.0)), 80.0) * exp(-r / 0.03);
    float glow = exp(-r / 0.006) * 0.6 + exp(-r / 0.035) * 0.15;
    col += kFlareColor * (glow + rays * 0.45) * pulseF;

    col += orbitingDebris(q, t, spin);
    float4 moon = orbitingMoon(q, t);
    col = col * (1.0 - moon.a) + moon.rgb;
    return col;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    return float4(animatePlanet(fragCoord * px, px, iTime, aspect), 1.0);
}
