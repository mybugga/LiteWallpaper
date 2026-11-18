// Astronaut: a photo of an astronaut on the right, looking out at a slowly turning sky with the
// Milky Way, thousands of stars and the odd shooting star. The sun glints on the visor and a helmet
// light blinks. The photo needs full resolution to stay sharp, hence the scale line.
// texture: assets/astronaut.png
// scale: 1

static const float2 kGlint = float2(551, 510);  // sun reflection in the visor, photo pixels
static const float2 kLed = float2(832, 426);    // orange light on the helmet

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

// Star colours roughly follow real star temperatures: mostly white and pale yellow, some blue, a few orange.
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
    if (hash21(id + 91.0) > 0.35) return 0;
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

// The Milky Way: a faint band of glowing gas cut by dark dust lanes. Returns colour, and in .w how
// dense the band is there (it carries extra stars).
float4 milkyWay(float2 p) {
    float2 q = rot(p - float2(0.55, 0.0), -0.76);
    float warp = fbm(q * 2.0) - 0.5;
    float y = q.y + warp * 0.12;
    float band = exp(-y * y / (2.0 * 0.16 * 0.16));
    float core = exp(-y * y / (2.0 * 0.06 * 0.06));
    float gas = fbm(q * float2(3.0, 6.0) + 4.0);
    float dust = smoothstep(0.45, 0.75, fbm(q * float2(5.0, 11.0) + 20.0)) * core;
    float3 col = lerp(float3(0.30, 0.38, 0.62), float3(0.95, 0.78, 0.60), core) * band * (0.35 + 0.9 * gas);
    col *= 1.0 - 0.85 * dust;
    return float4(col * 0.17, band * (1.0 - 0.7 * dust));
}

// Every few seconds, maybe, a thin streak crosses the sky.
float3 shootingStar(float2 p, float aspect, float t, float px) {
    const float period = 7.0;
    float k = floor(t / period), lt = t - k * period;
    if (hash21(float2(k, 3.3)) > 0.6 || lt > 1.4) return 0;
    float2 start = float2((0.1 + 0.6 * hash21(float2(k, 1.1))) * aspect, 0.65 + 0.3 * hash21(float2(k, 2.2)));
    float2 dir = normalize(float2(hash21(float2(k, 4.4)) > 0.5 ? 1.0 : -1.0, -0.35 - 0.4 * hash21(float2(k, 5.5))));
    float2 head = start + dir * lt * 0.55;
    float2 v = p - head;
    float along = dot(v, -dir), across = dot(v, float2(-dir.y, dir.x));
    float tail = 0.16 * saturate(lt * 3.0);
    float trail = exp(-across * across / (2.0 * px * px * 0.8)) * saturate(1.0 - along / tail) * step(-px * 1.5, along);
    float headGlow = exp(-length(v) / (px * 2.5)) * 0.6;
    float life = smoothstep(0.0, 0.15, lt) * smoothstep(1.4, 0.7, lt);
    return float3(0.85, 0.92, 1.0) * (trail + headGlow) * life * 1.2;
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y;
    float aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;  // screen-height units, origin bottom-left
    float t = iTime;

    // The whole sky turns very slowly about a point far below the screen.
    float2 sky = rot(p - float2(aspect * 0.5, -1.4), t * 0.0022) + float2(aspect * 0.5, -1.4);

    float4 mw = milkyWay(sky);
    float3 col = mw.rgb;
    col += starLayer(sky, 160.0, 0.30 + 0.5 * mw.w, 0.55, px, t, 0.0);
    col += starLayer(sky, 80.0, 0.30 + 0.3 * mw.w, 0.8, px, t, 17.0);
    col += starLayer(sky, 36.0, 0.20 + 0.2 * mw.w, 1.0, px, t, 41.0);
    col += starLayer(sky, 15.0, 0.28, 1.2, px, t, 73.0);
    col += brightStars(sky, px, t);
    col += shootingStar(p, aspect, t, px);
    col *= 1.0 - 0.25 * smoothstep(0.4, 1.3, length((p - float2(aspect, 1.0) * 0.5) / float2(aspect * 0.6, 0.6)));

    // The photo fills the screen height on the right. It breathes very slightly, anchored at its
    // bottom-right corner, which is where the photo is cropped.
    float tw, th;
    iChannel0.GetDimensions(tw, th);
    if (th > 0.0) {
        float breathe = 1.0 + 0.003 * sin(t * 0.8);
        float2 size = float2(tw / th, 1.0) * breathe;
        float2 fromCorner = float2(aspect - p.x, p.y);              // distance from the bottom-right
        float2 uv = float2(1.0 - fromCorner.x / size.x, 1.0 - fromCorner.y / size.y);
        if (uv.x >= 0.0 && uv.y >= 0.0 && uv.y <= 1.0) {
            float4 photo = iChannel0.Sample(iSampler, uv);         // premultiplied alpha
            col = col * (1.0 - photo.a) + photo.rgb;
        }

        // Sun glint on the visor: a soft core, slowly turning rays and a faint horizontal lens streak.
        float2 toPx = float2(size.x / tw, size.y / th);
        float2 gp = float2(aspect - (tw - kGlint.x) * toPx.x, (th - kGlint.y) * toPx.y);
        float2 d = p - gp;
        float r = length(d);
        float pulse = 0.85 + 0.15 * sin(t * 0.7) + 0.05 * sin(t * 2.3);
        float a = atan2(d.y, d.x) + t * 0.05;
        float rays = pow(abs(cos(a * 4.0)), 30.0) * exp(-r / 0.035) + pow(abs(cos(a * 3.0 + 1.0)), 60.0) * exp(-r / 0.022);
        float glow = exp(-r / 0.008) * 0.6 + exp(-r / 0.03) * 0.12;
        float streak = exp(-abs(d.y) / (px * 1.2)) * exp(-abs(d.x) / 0.18) * 0.25;
        col += float3(1.0, 0.72, 0.40) * (glow + rays * 0.5) * pulse + float3(0.55, 0.70, 1.0) * streak * pulse;

        // Helmet light: two quick blinks every few seconds.
        float2 lp = float2(aspect - (tw - kLed.x) * toPx.x, (th - kLed.y) * toPx.y);
        float cyc = frac(t / 3.0) * 3.0;
        float on = exp(-pow((cyc - 0.15) / 0.06, 2.0)) + exp(-pow((cyc - 0.45) / 0.06, 2.0));
        float lr = length(p - lp);
        col += float3(1.0, 0.45, 0.10) * on * (exp(-lr / (px * 3.0)) * 0.9 + exp(-lr / (px * 14.0)) * 0.25);
    }
    return float4(col, 1.0);
}
