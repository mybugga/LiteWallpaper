// Shared by the astronaut_* wallpapers: star fields, shooting stars, and the astronaut photo with
// its visor flare and helmet lights. Not a wallpaper itself (.hlsli files aren't listed).

// Where things are in the astronaut photos, as fractions of the image.
static const float2 kVisorUV = float2(0.7275, 0.1850);    // edge of the visor where the light catches
static const float2 kLedUV = float2(0.8935, 0.1180);      // orange light on the helmet
static const float2 kPackLedUV = float2(0.9815, 0.3316);  // orange light on the backpack

float hash21(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}
float2 rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }

float noise(float2 p) {
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash21(i), hash21(i + float2(1, 0)), f.x), lerp(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
}
float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 5; i++) { v += a * noise(p); p = rot(p, 0.6) * 2.03 + 11.7; a *= 0.5; }
    return v;
}
float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 3; i++) { v += a * noise(p); p = rot(p, 0.6) * 2.03 + 11.7; a *= 0.5; }
    return v / 0.875;
}

// ---- stars ---------------------------------------------------------------------------------------

// Roughly real star colours: mostly white and pale yellow, some blue, a few orange.
float3 starTint(float h) {
    if (h < 0.2) return float3(0.70, 0.80, 1.00);
    if (h < 0.6) return float3(1.00, 0.98, 0.95);
    if (h < 0.85) return float3(1.00, 0.90, 0.72);
    return float3(1.00, 0.72, 0.50);
}

// At most one star per cell, kept away from the cell edge so its glow is never cut off. Brightness
// follows a steep power law: most stars are barely there, a handful are bright.
float3 starLayer(float2 p, float cells, float chance, float gain, float px, float t, float seed) {
    float2 g = p * cells;
    float2 id = floor(g);
    float h = hash21(id + seed);
    if (h > chance) return 0;
    float2 c = id + 0.5 + (float2(hash21(id + seed + 1.3), hash21(id + seed + 7.1)) - 0.5) * 0.5;
    float d = length(g - c) / cells;
    float mag = pow(hash21(id + seed + 4.7), 8.0);
    float sigma = px * (0.75 + 0.8 * mag);
    float core = exp(-d * d / (2.0 * sigma * sigma));
    float bloom = exp(-d / (px * 5.0)) * 0.05 * mag;
    float shimmer = 1.0 + 0.12 * sin(t * (1.5 + 4.0 * h) + h * 90.0);
    return starTint(hash21(id + seed + 2.9)) * gain * (0.12 + 1.6 * mag) * (core + bloom) * shimmer;
}

// A few bright stars with the four-point diffraction spikes cameras give them.
float3 brightStars(float2 p, float px, float t) {
    const float cells = 6.0;
    float2 g = p * cells;
    float2 id = floor(g);
    if (hash21(id + 91.0) > 0.3) return 0;
    float2 c = id + 0.5 + (float2(hash21(id + 3.7), hash21(id + 8.3)) - 0.5) * 0.35;
    float2 d = (g - c) / cells;
    float m = 0.5 + 0.5 * hash21(id + 5.5);
    float r = length(d);
    float core = exp(-r * r / (2.0 * px * px * 1.6)) + exp(-r / (px * 3.0)) * 0.25 + exp(-r / (px * 14.0)) * 0.05;
    float spikes = (exp(-abs(d.y) / (px * 0.7)) * exp(-abs(d.x) / (px * 26.0 * m)) +
                    exp(-abs(d.x) / (px * 0.7)) * exp(-abs(d.y) / (px * 26.0 * m))) * 0.35;
    float shimmer = 1.0 + 0.08 * sin(t * 1.3 + hash21(id) * 40.0);
    return starTint(hash21(id + 6.1)) * m * (core + spikes) * shimmer;
}

// Stars drifting past with parallax, as if slowly moving through space: the nearer (brighter)
// layers slide faster than the distant ones. `extra` (0-1) adds stars, e.g. inside a nebula.
float3 starField(float2 p, float px, float t, float extra) {
    float2 v = float2(-0.0045, 0.0012) * t;
    float3 c = starLayer(p + v * 0.15, 160.0, 0.28 + 0.45 * extra, 0.55, px, t, 0.0);
    c += starLayer(p + v * 0.35, 80.0, 0.26 + 0.3 * extra, 0.8, px, t, 17.0);
    c += starLayer(p + v * 0.6, 36.0, 0.18 + 0.2 * extra, 1.0, px, t, 41.0);
    c += starLayer(p + v, 15.0, 0.26, 1.2, px, t, 73.0);
    c += brightStars(p + v, px, t);
    return c;
}

// Every few seconds, maybe, a thin streak crosses the sky.
float3 shootingStar(float2 p, float aspect, float t, float px, float3 tint) {
    const float period = 7.0;
    float k = floor(t / period), lt = t - k * period;
    if (hash21(float2(k, 3.3)) > 0.6 || lt > 1.4) return 0;
    float2 start = float2((0.1 + 0.6 * hash21(float2(k, 1.1))) * aspect, 0.65 + 0.3 * hash21(float2(k, 2.2)));
    float2 dir = normalize(float2(hash21(float2(k, 4.4)) > 0.5 ? 1.0 : -1.0, -0.35 - 0.4 * hash21(float2(k, 5.5))));
    float2 v = p - (start + dir * lt * 0.55);
    float along = dot(v, -dir), across = dot(v, float2(-dir.y, dir.x));
    float tail = 0.16 * saturate(lt * 3.0);
    float trail = exp(-across * across / (2.0 * px * px * 0.8)) * saturate(1.0 - along / tail) * step(-px * 1.5, along);
    float headGlow = exp(-length(v) / (px * 2.5)) * 0.6;
    float life = smoothstep(0.0, 0.15, lt) * smoothstep(1.4, 0.7, lt);
    return tint * (trail + headGlow) * life * 1.2;
}

float vignette(float2 p, float aspect) {
    return 1.0 - 0.3 * smoothstep(0.4, 1.3, length((p - float2(aspect, 1.0) * 0.5) / float2(aspect * 0.6, 0.6)));
}

// ---- the space photo behind (iChannel1) ----------------------------------------------------------

// Where screen point p lands in the space photo. The photo's point `anchorUV` sits at screen point
// `at`, the photo is `height` screen-heights tall and turned by `angle`. It drifts and zooms very
// slowly (cycles of ten minutes or so), like a camera floating.
float2 backdropUV(float2 p, float2 at, float2 anchorUV, float height, float angle, float t) {
    float tw, th;
    iChannel1.GetDimensions(tw, th);
    float zoom = 1.0 + 0.035 * sin(t * 0.011);
    float2 drift = float2(sin(t * 0.0071), cos(t * 0.0093)) * 0.012;
    float2 v = rot(p - at - drift, -angle) / (height * zoom);
    return anchorUV + float2(v.x * th / max(tw, 1.0), -v.y);
}

// The reverse: where a point of the space photo is on screen right now.
float2 backdropToScreen(float2 uv, float2 at, float2 anchorUV, float height, float angle, float t) {
    float tw, th;
    iChannel1.GetDimensions(tw, th);
    float zoom = 1.0 + 0.035 * sin(t * 0.011);
    float2 drift = float2(sin(t * 0.0071), cos(t * 0.0093)) * 0.012;
    float2 v = (uv - anchorUV) * float2(tw / max(th, 1.0), -1.0);
    return at + drift + rot(v * height * zoom, angle);
}

float3 backdrop(float2 uv) {
    if (any(uv < 0.0) || any(uv > 1.0)) return 0;
    return iChannel1.SampleLevel(iSampler, uv, 0).rgb;
}

// ---- the photo -----------------------------------------------------------------------------------

// The photo (iChannel0) fills the screen height, anchored bottom-right where it is cropped, and
// breathes very slightly. Returns premultiplied colour; `size` is its on-screen size.
float4 samplePhoto(float2 p, float aspect, float t, out float2 size) {
    float tw, th;
    iChannel0.GetDimensions(tw, th);
    size = float2(tw / max(th, 1.0), 1.0) * (1.0 + 0.003 * sin(t * 0.8));
    float2 uv = float2(1.0 - (aspect - p.x) / size.x, 1.0 - p.y / size.y);
    if (th <= 0.0 || uv.x < 0.0) return 0;
    return iChannel0.Sample(iSampler, uv);
}

float2 photoToScreen(float2 uv, float2 size, float aspect) { return float2(aspect - (1.0 - uv.x) * size.x, (1.0 - uv.y) * size.y); }

// Light catching the edge of the visor: a soft core, slowly turning rays and a faint lens streak.
float3 visorFlare(float2 p, float2 at, float px, float t, float3 color) {
    float2 d = p - at;
    float r = length(d);
    float pulse = 0.85 + 0.15 * sin(t * 0.7) + 0.05 * sin(t * 2.3);
    float a = atan2(d.y, d.x) + t * 0.05;
    float rays = pow(abs(cos(a * 4.0)), 30.0) * exp(-r / 0.035) + pow(abs(cos(a * 3.0 + 1.0)), 60.0) * exp(-r / 0.022);
    float glow = exp(-r / 0.008) * 0.5 + exp(-r / 0.03) * 0.1;
    float streak = exp(-abs(d.y) / (px * 1.2)) * exp(-abs(d.x) / 0.18) * 0.22;
    return color * (glow + rays * 0.5 + streak) * pulse;
}

// The helmet light double-blinks every three seconds; the backpack light breathes slowly.
float3 suitLights(float2 p, float2 size, float aspect, float px, float t) {
    float cyc = frac(t / 3.0) * 3.0;
    float on = exp(-pow((cyc - 0.15) / 0.06, 2.0)) + exp(-pow((cyc - 0.45) / 0.06, 2.0));
    float r1 = length(p - photoToScreen(kLedUV, size, aspect));
    float r2 = length(p - photoToScreen(kPackLedUV, size, aspect));
    float pack = 0.5 + 0.5 * sin(t * 1.4);
    float3 orange = float3(1.0, 0.45, 0.10);
    return orange * (on * (exp(-r1 / (px * 3.0)) * 0.9 + exp(-r1 / (px * 14.0)) * 0.25) +
                     pack * (exp(-r2 / (px * 4.0)) * 0.5 + exp(-r2 / (px * 16.0)) * 0.15));
}
