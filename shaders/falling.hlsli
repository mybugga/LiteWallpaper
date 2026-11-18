// Shared by wallpapers with falling petals or leaves. Each one is a small 3D object: a cupped
// petal or folded leaf that falls, drifts with the wind, sways, flutters and tumbles, shaded with
// soft light, light glowing through it from behind and a faint sheen. Needs space.hlsli.

static const float3 kFallLight = normalize(float3(-0.45, 0.6, 0.65));  // soft key light, upper left

struct FallStyle {
    int kind;         // 0 = sakura petal, 1 = leaf
    float3 base;      // colour near the stem
    float3 tip;       // colour toward the tip
    float3 back;      // colour of the back face
    float3 through;   // colour of light shining through it from behind
    float3 alt;       // about a fifth take this colour instead (yellowing leaves); 0 = never
    float glow;       // glows by itself, with a halo (neon)
    float windX;      // sideways drift per unit of fall (negative = left)
    float rightBias;  // 0 = spread evenly, 1 = more toward the right of the screen
    float floorY;     // they vanish on reaching this height (screen-height units); -1 = never
};

float3 rotateAbout(float3 v, float3 axis, float a) {
    float c = cos(a), s = sin(a);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

// Smooth maximum: joins shape edges with rounded corners, so blurred edges don't streak.
float smax(float a, float b, float k) {
    float h = saturate(0.5 - 0.5 * (b - a) / k);
    return lerp(b, a, h) + k * h * (1.0 - h);
}

// Shapes in their own plane: x across, y from the stem (-1) to the tip (+1). Signed distance,
// negative inside.

// A sakura petal: narrow at the base, widest past the middle, rounded at the tip with the notch.
float petalShape(float2 l) {
    float t = (l.y + 1.0) * 0.5;
    float w = t < 0.62 ? 0.62 * pow(saturate(t / 0.62), 0.5) : 0.62 * sqrt(saturate(1.0 - pow((t - 0.62) / 0.38, 2.0)));
    float tip = 1.0 - 0.13 * saturate(1.0 - abs(l.x) / 0.16);  // the notch
    return smax(smax(abs(l.x) - w, t - tip, 0.04), 0.04 - t, 0.04);  // base trimmed so it isn't a spike
}

// A leaf: a pointed oval, widest a little below the middle, on a short stalk.
float leafShape(float2 l) {
    float t = (l.y + 1.0) * 0.5;
    float blade = (t - 0.1) / 0.9;
    float w = 0.4 * pow(saturate(sin(3.1416 * pow(saturate(blade), 0.8))), 0.75);
    float stalk = abs(l.x) - 0.025;
    float d = t < 0.1 ? stalk : smax(abs(l.x) - w, t - 1.0, 0.02);
    return max(d, -t);
}

// One depth of falling petals or leaves. Each cell may hold one that falls, drifts, sways and
// tumbles in 3D; it stays inside its cell so one lookup per pixel is enough. `soft` widens the
// edges for ones out of focus; `extraLight` is coloured light falling on it here. Returns
// premultiplied colour.
float4 fallingLayer(float2 p, float aspect, float t, float cell, float speed, float size, float density, float seed,
                    float soft, float3 extraLight, float px, FallStyle st) {
    float2 fall = float2(st.windX, -1.0) * speed * t;
    float2 g = (p - fall) / cell;
    float2 id = floor(g);
    float h = hash21(id + seed);
    float sx = (id.x + 0.5) * cell + fall.x;
    if (h > density * lerp(0.35, 0.18 + 0.32 * smoothstep(0.3, 1.0, sx / aspect), st.rightBias)) return 0;
    float r1 = hash21(id + seed + 1.0), r2 = hash21(id + seed + 2.0), r3 = hash21(id + seed + 3.0);
    float r4 = hash21(id + seed + 4.0), r5 = hash21(id + seed + 5.0), r6 = hash21(id + seed + 6.0);
    float2 c = id + 0.5 + (float2(r2, r3) - 0.5) * 0.3;
    c.x += 0.14 * sin(t * (0.7 + 0.5 * r4) + r1 * 6.28);  // sway
    c.y += 0.05 * sin(t * (1.1 + 0.6 * r5) + r1 * 12.0);   // flutter
    float alive = 1.0;
    if (st.floorY > -0.5) {
        float cy = (id.y + c.y) * cell + fall.y;  // its height on screen
        alive = smoothstep(st.floorY - 0.004, st.floorY + 0.008, cy);
        if (alive <= 0.0) return 0;
    }
    float sz = size * (0.8 + 0.4 * r6);
    float2 d = (g - c) * cell / sz;
    if (dot(d, d) > (st.glow > 0.0 ? 2.8 : 1.6)) return 0;

    // Orientation: a random starting pose rocking about a random axis, with a slow full turn now
    // and then, so the face is usually seen.
    float3 axis = normalize(float3(r2 - 0.5, r3 - 0.5, r4 - 0.5) + 0.01);
    float ang = r1 * 6.28 + t * (0.15 + 0.3 * r5) * (r6 > 0.5 ? 1.0 : -1.0) + 1.0 * sin(t * (0.9 + 0.9 * r4) + r2 * 6.28);
    float3 u0 = normalize(float3(cos(r1 * 6.28), sin(r1 * 6.28), (r2 - 0.5) * 0.6));
    float3 v0 = normalize(cross(float3((r3 - 0.5) * 0.6, (r4 - 0.5) * 0.6, 1.0), u0));
    float3 u = rotateAbout(u0, axis, ang), v = rotateAbout(v0, axis, ang);
    float3 n = normalize(cross(u, v));

    // Which point of its plane lies under this pixel (looking straight on).
    float det = u.x * v.y - u.y * v.x;
    float sd = sign(det) * max(abs(det), 0.06);
    float2 l = float2(d.x * v.y - d.y * v.x, u.x * d.y - u.y * d.x) / sd;
    float dist = st.kind == 0 ? petalShape(l) : leafShape(l);
    float aa = (px / sz + soft) / sqrt(abs(sd));
    float cover = smoothstep(aa, -aa, dist);
    float halo = st.glow > 0.0 ? exp(-max(dist, 0.0) / 0.16) * st.glow * 0.35 * (1.0 - cover) : 0.0;
    if (cover <= 0.0 && halo <= 0.002) return 0;

    // A petal is cupped across its width; a leaf folds along its midrib and curls along its length.
    float3 bend = st.kind == 0 ? normalize(float3(-l.x * 0.9, -0.25 * (l.y + 0.2), 1.0))
                               : normalize(float3(-sign(l.x) * 0.45 - l.x * 0.4, -0.3 * l.y, 1.0));
    float3 nn = normalize(u * bend.x + v * bend.y + n * bend.z);
    bool front = nn.z > 0.0;
    float3 nf = front ? nn : -nn;

    // Colour from stem to tip, with veins and paler edges.
    float tt = (l.y + 1.0) * 0.5;
    float3 tipCol = st.tip, baseCol = st.base;
    if (dot(st.alt, 1.0) > 0.0 && hash21(id + seed + 7.0) < 0.22) {
        baseCol = lerp(baseCol, st.alt * 0.8, 0.8);
        tipCol = lerp(tipCol, st.alt, 0.8);
    }
    float3 col0 = lerp(baseCol, lerp(baseCol, tipCol, 0.6), smoothstep(0.0, 0.5, tt));
    col0 = lerp(col0, tipCol, smoothstep(0.55, 1.0, tt) * 0.7);
    float detail = saturate(1.0 - soft * 8.0);
    if (st.kind == 0) {
        float vein = pow(0.5 + 0.5 * cos(atan2(l.x, tt + 0.25) * 34.0), 8.0) * smoothstep(0.05, 0.4, tt);
        col0 *= 1.0 - 0.03 * vein * detail;
    } else {
        float midrib = exp(-abs(l.x) / 0.02);
        float side = pow(0.5 + 0.5 * cos((l.y - abs(l.x) * 1.4) * 22.0), 12.0) * smoothstep(0.02, 0.08, abs(l.x));
        col0 = lerp(col0, col0 * 1.4 + 0.04, (midrib * 0.6 + side * 0.18) * detail);
    }
    col0 = lerp(col0, saturate(tipCol * 1.08), smoothstep(-0.08, 0.0, dist) * 0.3);
    if (!front) col0 = lerp(col0, st.back, 0.3);  // the back is paler and matte

    float diffuse = saturate(dot(nf, kFallLight));
    float through = saturate(-dot(nf, kFallLight));  // light shining through from behind
    float3 halfV = normalize(kFallLight + float3(0, 0, 1));
    float sheen = pow(saturate(dot(nf, halfV)), st.kind == 0 ? 24.0 : 40.0) * (front ? (st.kind == 0 ? 0.22 : 0.3) : 0.06);
    float3 col = col0 * (0.42 + 0.7 * diffuse) + st.through * through * 0.4 * (1.15 - tt * 0.3) + sheen;
    col += extraLight * (0.4 + 0.6 * through);
    col += col0 * st.glow;
    return float4(col * cover + lerp(st.tip, st.base, 0.5) * halo, cover) * alive;
}

FallStyle sakuraPetals() {
    FallStyle st = (FallStyle)0;
    st.kind = 0;
    st.base = float3(0.82, 0.24, 0.45);
    st.tip = float3(1.0, 0.72, 0.82);
    st.back = float3(0.92, 0.66, 0.76);
    st.through = float3(1.0, 0.4, 0.62);
    st.windX = -0.35;
    st.rightBias = 1.0;
    st.floorY = -1.0;
    return st;
}
