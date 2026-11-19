// Dragon: a black dragon veined with fire, alive. It looks slowly about, breathes deeply with its chest
// swelling and smoke puffing from its nostrils, beats its wings and blinks. Every so often (never on
// a fixed beat) the fire inside it climbs its neck, glowing through the cracks, and it rears back,
// lunges and breathes a roaring blast of fire out of its jaws: a rolling fireball, sparks flying, heat
// shimmering round it and smoke curling off it that hangs and rises afterwards, with the blast lighting
// its face, the wing and everything along its path. Some bouts it only growls and snorts out smoke.
// Flames lick up along the bottom and light it from below, the molten cracks glow and flow, smoke
// streams from its jaws between blasts, smoke rolls round its feet and embers rise.
// texture: assets/dragon.jpg
// scale: 1
#include "space.hlsli"

static const float2 kImg = float2(1672.0, 941.0);    // picture pixels the positions below use
static const float2 kEye = float2(1160.0, 290.0);
static const float2 kMouth = float2(1235.0, 470.0);  // where the smoke leaves the jaws
static const float2 kJaws = float2(1262.0, 480.0);   // where the fire leaves the open jaws
static const float2 kNostril = float2(1322.0, 334.0);
static const float2 kChest = float2(900.0, 720.0);   // the chest swells about here
static const float2 kNeck = float2(930.0, 770.0);    // the head and neck turn about the base of the neck
static const float2 kHinge = float2(1125.0, 400.0);  // the lower jaw opens about here
static const float2 kShoulderL = float2(500.0, 600.0), kShoulderR = float2(1110.0, 760.0);  // the wings beat from here
static const float2 kNeckBase = float2(920.0, 940.0), kThroat = float2(1170.0, 470.0);     // the fire climbs between these

float3 picture(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }

// The head's outline on the right at height y (snout, fangs, lower jaw), traced from the picture.
float headEdge(float y) {
    if (y < 300.0) return lerp(1290.0, 1320.0, saturate((y - 200.0) / 100.0));
    if (y < 345.0) return lerp(1320.0, 1345.0, (y - 300.0) / 45.0);
    if (y < 440.0) return lerp(1345.0, 1322.0, (y - 345.0) / 95.0);
    if (y < 470.0) return lerp(1322.0, 1275.0, (y - 440.0) / 30.0);
    if (y < 530.0) return lerp(1275.0, 1258.0, (y - 470.0) / 60.0);
    return lerp(1258.0, 1150.0, saturate((y - 530.0) / 170.0));
}

// 1 away from the dragon, 0 on its head or right wing: smoke and shimmer stay off them, so its face
// never ripples like smoke.
float notDragon(float2 q) {
    float edge = headEdge(q.y);
    float head = smoothstep(edge + 16.0, edge + 2.0, q.x);
    // The right wing's leading edge runs from (1350, 690) up to (1645, 245); the wing is beyond it.
    float2 d = normalize(float2(295.0, -445.0));
    float side = d.x * (q.y - 690.0) - d.y * (q.x - 1350.0);
    float wing = smoothstep(-18.0, -4.0, side);
    return (1.0 - head) * (1.0 - wing);
}

// Where the picture has smoke: in front of the jaws only.
float jawSmoke(float2 q) {
    float2 dm = q - kMouth;
    return smoothstep(0.0, 40.0, dm.x) * smoothstep(380.0, 250.0, dm.x) * smoothstep(170.0, 80.0, abs(dm.y + 40.0)) * notDragon(q);
}
float smokeMask(float2 q) { return jawSmoke(q); }
#include "fx.hlsli"

// Fire colour by heat: dark red, orange, yellow, then white-hot.
float3 fireRamp(float k) {
    return float3(1.0, 0.28, 0.05) * smoothstep(0.0, 0.45, k) + float3(0.0, 0.42, 0.12) * smoothstep(0.35, 0.8, k) +
           float3(0.0, 0.25, 0.4) * smoothstep(0.75, 1.0, k);
}

// The blast of fire, in its own frame: `along` from the jaws, `across` it (picture pixels). It billows
// wider as it goes, with a rolling ball of fire at its front. Heat 0-1.
float breathFire(float along, float across, float t, float reach, float env) {
    if (env <= 0.001 || along < -40.0 || along > reach + 60.0) return 0.0;
    float width = (16.0 + max(along, 0.0) * 0.42) * (1.0 + 0.7 * exp(-pow((along - reach + 90.0) / 80.0, 2.0)));
    // Billows: noise carried outwards fast, folded by more noise.
    float2 w = float2(along / 75.0 - t * 4.0, across / 48.0);
    float2 fold = float2(fbm3(w + 1.3), fbm3(w + 6.1)) - 0.5;
    float n = fbm3(w * 1.3 + fold * 1.6);
    float n2 = fbm3(float2(along / 24.0 - t * 8.0 + 4.0, across / 16.0 + 2.0));
    float body = exp(-pow((across + fold.y * width * 1.3) / width, 2.0));
    float k = body * (0.3 + 0.95 * n) * (0.75 + 0.35 * n2);
    k *= smoothstep(-35.0, 5.0, along) * smoothstep(reach, reach - 170.0, along);
    k *= 1.0 - 0.5 * saturate(along / reach);  // hottest at the jaws
    return saturate(k * 1.25) * env;
}

// Sparks flung out of the blast, in its frame: bright specks streaking outwards, spreading with it and
// fading as they cool. In their own moving frame they stand still, on a grid.
float blastSparks(float along, float across, float t, float reach) {
    const float speed = 520.0, cell = 46.0, lane = 0.55;
    float u = along - t * speed;
    float v = across / (20.0 + max(along, 0.0) * 0.5);
    float2 g = float2(u / cell, v / lane);
    float2 id = floor(g);
    float bright = 0.0;
    [unroll] for (int j = -1; j <= 1; j++)
    [unroll] for (int i = -1; i <= 1; i++) {
        float2 cid = id + float2(i, j);
        if (hash21(cid + 17.0) > 0.45 || abs((cid.y + 0.5) * lane) > 1.0) continue;  // only within the flames' width
        float pu = (cid.x + hash21(cid + 3.1)) * cell;
        float pAlong = pu + t * speed;
        float pAcross = (cid.y + hash21(cid + 5.7)) * lane * (20.0 + max(pAlong, 0.0) * 0.5);
        float d = length(float2((u - pu) / 3.5, across - pAcross));  // streaks along the blast
        float life = smoothstep(reach + 60.0, reach * 0.4, pAlong) * smoothstep(20.0, 70.0, pAlong);
        bright += exp(-d * d / 3.0) * life * (0.5 + 0.5 * hash21(cid + 9.3));
    }
    return bright;
}

// Flames licking up along the bottom of the scene, in patches with gaps between them that slowly
// shift. Heat 0-1.
float floorFire(float2 q, float t) {
    float h = kImg.y - q.y;  // picture pixels above the bottom edge
    if (h > 300.0) return 0.0;
    float patch = smoothstep(0.3, 0.62, fbm3(float2(q.x / 280.0 + 3.0, t * 0.07)));
    float tall = 40.0 + 220.0 * patch;
    float2 w = float2(q.x / 70.0, (q.y + t * 150.0) / 80.0);  // carried upwards
    float2 fold = float2(fbm3(w * 0.7 + 1.7), fbm3(w * 0.7 + 8.3)) - 0.5;
    float n = fbm3(w + fold * 1.2);
    float n2 = fbm3(float2(q.x / 30.0 + 5.0, (q.y + t * 230.0) / 26.0));
    float k = (n * 0.8 + n2 * 0.35) * (0.55 + 0.45 * patch) - h / tall;
    return saturate(k * 1.5) * 0.85;
}

// ---- How it moves: everything is a smooth warp of its own picture ----

// The right wing lies beyond its leading edge, from (1250, 700) up to (1640, 100); the left wing is
// left of about x = 470.
float rightWing(float2 q) {
    float2 d = normalize(float2(390.0, -600.0));
    return smoothstep(-40.0, 10.0, d.x * (q.y - 700.0) - d.y * (q.x - 1250.0));
}
float leftWing(float2 q) { return smoothstep(520.0, 420.0, q.x); }

// How much of the head-and-neck turn a point follows: all of it at the head, less and less down the
// neck, none on the wings. Turning with a weight like this bends the neck rather than cutting it.
float headWeight(float2 q) { return smoothstep(760.0, 400.0, q.y) * smoothstep(430.0, 580.0, q.x) * (1.0 - rightWing(q)); }

// The lower jaw: the wedge below the hinge between the upper fangs and the throat. Its inner edge
// is the dark inside of the mouth, which stretches as the jaw opens.
float jawWeight(float2 q) {
    float2 v = q - kHinge;
    float ang = degrees(atan2(v.y, v.x)), r = length(v);
    return smoothstep(12.0, 30.0, ang) * smoothstep(105.0, 88.0, ang) * smoothstep(25.0, 60.0, r) * smoothstep(340.0, 280.0, r);
}

// Turns what's at q by `a` radians about `pivot`, as much as `w` says (sampling backwards).
float2 turn(float2 q, float2 pivot, float a, float w) { return pivot + rot(q - pivot, -a * w); }

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;

    // ---- What it's doing now ----
    // A bout every twelve seconds, each one different: when it rears up, how long it breathes fire,
    // and whether it breathes fire at all (now and then it only growls and snorts smoke: only ever on
    // odd bouts, so never twice running, and the first bout after it starts always breathes fire).
    // It draws itself up and rears back, lunges as the fire comes, shakes with the blast, then settles.
    float bout = floor(t / 12.0), c = t - bout * 12.0;
    float start = 4.6 + 2.0 * hash21(float2(bout, 3.1));   // when the fire (or the growl) comes
    float dur = 1.8 + 1.6 * hash21(float2(bout, 7.7));     // how long the fire lasts
    float fires = (frac(bout * 0.5) > 0.25 && hash21(float2(bout, 11.3)) < 0.4) ? 0.0 : 1.0;
    float end = start + lerp(1.2, dur, fires);
    float rear = smoothstep(start - 1.3, start - 0.1, c);
    float lunge = smoothstep(start - 0.05, start + 0.35, c);
    float settle = smoothstep(end, end + 1.2, c);
    float rearing = rear * (1.0 - lunge), blast = lunge * (1.0 - settle);
    float strength = lerp(0.55, 1.0, fires);  // a growl is a smaller version of it
    float fireOn = fires * smoothstep(start, start + 0.3, c) * smoothstep(start + dur + 0.5, start + dur - 0.2, c);
    float grow = smoothstep(start, start + 0.7, c);  // the blast rolling out
    float snort = (1.0 - fires) * smoothstep(start, start + 0.15, c) * smoothstep(start + 1.8, start + 0.4, c);
    float afterburn = fires * smoothstep(start + dur - 0.4, start + dur + 0.3, c) * exp(-max(c - start - dur, 0.0) / 2.0) *
                      smoothstep(12.0, 10.8, c);

    // Breathing: the chest swells and the head lifts on each breath in; it draws a deep breath as it rears.
    float breath = 0.5 + 0.5 * sin(t * 0.9);
    float inhale = breath * 0.6 + rearing * strength;
    float exhale = smoothstep(0.0, -0.6, cos(t * 0.9));

    // ---- Moving its own picture ----
    // The head and neck: looking slowly about, rearing back, lunging, shaking while it breathes fire.
    float look = radians(1.2 * sin(t * 0.43) + 0.5 * sin(t * 0.97 + 1.0));
    float head = look + radians((-3.5 * rearing + 2.5 * blast) * strength - 0.6 * inhale) +
                 radians(0.35) * sin(t * 31.0) * sin(t * 17.0) * fireOn;
    // The jaw opens wide for the fire, and a little with each breath.
    float jaw = radians((4.5 * blast + 1.5 * rearing) * strength + 0.6 * breath);
    // The wings beat slowly, spreading wider while it breathes fire.
    float beat = radians(2.2 * sin(t * 1.35) + 1.5 * blast * strength);

    // The fire leaves the jaws wherever the head has moved them, pointing the way the head points.
    float aim = head * headWeight(kJaws);
    float2 jaws = kNeck + rot(kJaws - kNeck, aim);
    float2 dir = rot(normalize(float2(1.0, 0.12)), aim);
    float reach = 110.0 + 480.0 * grow;
    float2 fl = q - jaws;
    float fa = dot(fl, dir), fc = dot(fl, float2(-dir.y, dir.x));

    float2 qs = turn(q, kNeck, head, headWeight(q));  // head and neck
    float2 qh = qs;                                    // where the head's own picture is
    qs = turn(qs, kHinge, jaw, jawWeight(qs));         // lower jaw
    float2 vc = (qs - kChest) / float2(280.0, 230.0);
    qs = kChest + (qs - kChest) / (1.0 + 0.016 * inhale * exp(-dot(vc, vc)));  // chest swell
    qs = turn(qs, kShoulderL, beat, leftWing(q));      // wings
    qs = turn(qs, kShoulderR, -beat, rightWing(q));

    // Heat shimmer round the blast bends what's behind it (never the dragon's face), and the air shimmers
    // just above the flames along the bottom.
    float hot = fireOn * exp(-pow(fc / (40.0 + max(fa, 0.0) * 0.8), 2.0)) * smoothstep(-30.0, 40.0, fa) *
                smoothstep(reach + 160.0, reach - 40.0, fa) * notDragon(qh) +
                0.25 * smoothstep(760.0, 880.0, q.y);
    if (hot > 0.01)
        qs += (float2(noise(q / 17.0 + float2(t * 3.1, -t * 4.3)), noise(q / 17.0 + float2(7.3 - t * 2.7, 1.9 - t * 4.1))) - 0.5) * 6.0 * hot;

    // The smoke in front of its jaws streams away and rises (only the smoke: never the dragon).
    float3 col = streamSmoke(qs, t, float2(22.0, -9.0));

    // Molten cracks: fire flows through them and they pulse with the breath.
    float lava = saturate((col.r - max(col.g, col.b) - 0.12) * 3.0) * smoothstep(0.1, 0.4, col.r);
    float flow = fbm3(qs / 55.0 + float2(t * 0.05, -t * 0.12));
    col += col * lava * (0.7 * (flow - 0.35) + 0.35 * inhale);
    col += float3(1.0, 0.45, 0.1) * lava * smoothstep(0.6, 0.85, flow) * 0.25;  // white-hot spots

    // Before each blast the fire inside climbs its neck: a bright front rising through the cracks from the
    // chest to the throat, leaving them glowing hot behind it until it has breathed the fire out.
    float2 axis = kThroat - kNeckBase;
    float neckLen = length(axis);
    axis /= neckLen;
    float2 rel = qs - kNeckBase;
    float s = dot(rel, axis) / neckLen, lat = abs(dot(rel, float2(-axis.y, axis.x)));
    float neck = exp(-pow(lat / 190.0, 2.0)) * smoothstep(-0.15, 0.05, s) * smoothstep(1.3, 1.05, s);
    float front = 1.15 * smoothstep(start - 1.4, start, c);
    float gate = smoothstep(start - 1.5, start - 1.2, c) * (1.0 - settle) * lerp(0.5, 1.0, fires);
    float charged = smoothstep(front + 0.03, front - 0.12, s), band = exp(-pow((s - front) / 0.07, 2.0));
    col += col * lava * neck * gate * (charged * (0.9 + 0.3 * sin(t * 19.0)) + band * 1.6);
    col += float3(1.0, 0.55, 0.2) * lava * neck * gate * band * 0.3;

    // The eye: it burns brighter and dimmer, flares as it breathes fire, and now and then it blinks.
    float b1 = frac(t / 7.3) * 7.3, b2 = frac(t / 13.7 + 0.4) * 13.7;
    float blink = max(smoothstep(2.3, 2.37, b1) * smoothstep(2.55, 2.43, b1), smoothstep(9.0, 9.07, b2) * smoothstep(9.25, 9.13, b2));
    float2 ve = qs - kEye;
    col *= 1.0 - 0.85 * blink * exp(-dot(ve / float2(34.0, 16.0), ve / float2(34.0, 16.0)));
    float re = length(ve) / kImg.y;
    col += float3(1.0, 0.15, 0.05) * (exp(-re / 0.008) * 0.5 + exp(-re / 0.03) * 0.12) * (0.55 + 0.45 * sin(t * 1.3) + 0.6 * blast) * (1.0 - blink);
    // The throat glows, hottest just before the fire comes.
    float rt = length((qs - float2(1205.0, 480.0)) * float2(1.0, 1.6)) / kImg.y;
    col += float3(1.0, 0.3, 0.05) * exp(-rt / 0.03) * (0.12 * (0.6 + 0.4 * breath) + 0.35 * rear * (1.0 - settle) * lerp(0.4, 1.0, fires));

    // Smoke streaming from the jaws between blasts, thickest as it breathes out; it moves with the head.
    float2 dm = qh - kMouth;
    float along = dm.x;
    if (along > -10.0 && along < 420.0) {
        float spread = 12.0 + along * 0.35;
        float centre = -along * 0.28 - 0.0004 * along * along;  // rises as it drifts away
        float plume = exp(-pow((dm.y - centre) / spread, 2.0)) * smoothstep(-10.0, 30.0, along) * exp(-along / 260.0);
        float puffs = fbm3(float2(along / 45.0 - t * 0.9, dm.y / 40.0 + t * 0.1));
        col += float3(0.5, 0.47, 0.47) * plume * smoothstep(0.35, 0.8, puffs) * (0.3 + 0.4 * (1.0 - breath)) * (1.0 - 0.8 * fireOn) * notDragon(qh);
    }

    // Puffs of smoke from its nostrils each time it breathes out; a big snort when it growls.
    float puff = exhale * 0.45 * (1.0 - fireOn) + snort * 0.8;
    if (puff > 0.01) {
        float2 nd = normalize(float2(1.0, -0.22));
        float2 dn = qh - kNostril;
        float na = dot(dn, nd), nc = dot(dn, float2(-nd.y, nd.x));
        if (na > -5.0 && na < 260.0) {
            float plume = exp(-pow(nc / (6.0 + na * 0.33), 2.0)) * smoothstep(-5.0, 15.0, na) * exp(-na / (80.0 + 50.0 * snort));
            float wisp = fbm3(float2(na / 42.0 - t * 1.6, nc / 30.0 + t * 0.2)) * 0.7 + fbm3(float2(na / 20.0 - t * 2.4 + 5.0, nc / 15.0)) * 0.3;
            col += float3(0.42, 0.4, 0.4) * plume * smoothstep(0.32, 0.78, wisp) * puff * notDragon(qh);
        }
    }

    // Smoke the blast throws off: curling from its edges while it burns, then hanging in the air and
    // rising after it stops. A growl coughs out a cloud of it instead.
    float smokeAmt = 0.45 * fireOn + 0.9 * afterburn + 1.1 * snort;
    if (smokeAmt > 0.01) {
        float rise = 30.0 * max(c - start, 0.0);
        float2 sd = fl + float2(0.0, rise);  // the cloud rises as it drifts
        float sa = dot(sd, dir), sc = dot(sd, float2(-dir.y, dir.x));
        float sreach = lerp(260.0, reach + 120.0, fires);
        float sw = 30.0 + max(sa, 0.0) * 0.5 + rise * 0.6;
        float cone = exp(-pow(sc / sw, 2.0)) * smoothstep(-10.0, 70.0, sa) * smoothstep(sreach + 200.0, sreach - 60.0, sa);
        if (cone > 0.01) {
            // Soft billows rolling outwards (as in the smoke from its jaws).
            float billow = fbm3(float2(sa / 70.0 - t * 1.4, sc / 55.0 + t * 0.2)) * 0.75 + fbm3(float2(sa / 32.0 - t * 2.1 + 3.0, sc / 26.0 - t * 0.3)) * 0.35;
            float dens = min(cone * smoothstep(0.32, 0.85, billow) * smokeAmt * notDragon(qh), 0.8);
            col += dens * (float3(0.3, 0.28, 0.27) + float3(0.6, 0.25, 0.06) * fireOn);
        }
    }

    // The blast lights everything along its path (the face, the jaw, the wing), flickering.
    float segA = clamp(fa, 0.0, reach);
    float glow = fireOn * exp(-length(fl - dir * segA) / 230.0) * (0.88 + 0.12 * sin(t * 27.0));
    float nearJaws = exp(-length((q - jaws) * float2(0.8, 1.0)) / 170.0);
    col += col * float3(1.0, 0.42, 0.1) * (glow * 2.2 + fireOn * nearJaws * 1.8);
    col += float3(1.0, 0.35, 0.08) * glow * 0.05;  // the hot air glowing

    // Smoke rolling low around its feet, lit by the fire.
    float low = smoothstep(700.0, 900.0, q.y);
    if (low > 0.01) {
        float d = smokeDensity(q, t, float2(16.0, -5.0), 220.0) * low;
        col += float3(0.2, 0.08, 0.06) * d * 0.8;
    }

    // Flames along the bottom, and their flickering light on the dragon above them.
    float flicker = 0.8 + 0.2 * sin(t * 9.0) * sin(t * 13.7 + 1.0);
    col += col * float3(1.0, 0.38, 0.1) * smoothstep(560.0, 941.0, q.y) * 0.7 * flicker;
    float ff = floorFire(q, t);
    col += fireRamp(ff) * ff * 1.1;

    // The blast itself, and the sparks flying out of it.
    float heat = breathFire(fa, fc, t, reach, fireOn);
    col += fireRamp(heat) * heat * 1.8;
    if (fireOn > 0.01 && fa > -20.0 && fa < reach + 100.0)
        col += float3(1.0, 0.75, 0.35) * blastSparks(fa, fc, t, reach) * fireOn * 1.4;

    // Embers rising from the fire below.
    col += embers(p, t, 0.08, 0.05, 0.0012, 0.3, 3.0, px, float3(1.0, 0.35, 0.08));
    col += embers(p, t, 0.15, 0.09, 0.002, 0.22, 9.0, px, float3(1.0, 0.45, 0.12)) * 0.8;
    return float4(col, 1.0);
}
