// Book portal: an old book lying open, its pages cut into a gothic arch with a stair climbing to a
// sunlit autumn forest, and a girl in a red cloak walking up into it. The low sun glows and its rays
// shimmer through the arch, the trees beyond stir in the breeze, dappled light plays over the
// stairs with dust drifting in the beam, her cloak flutters, and the cut-paper leaves tremble.
// texture: assets/book_portal.jpg
// scale: 1
// aspect: 0.45
#include "ring.hlsli"
float smokeMask(float2 q) { return 0.0; }
#include "fx.hlsli"

static const float2 kSun = float2(1480.0, 690.0);    // picture pixels
static const float2 kArch = float2(1430.0, 760.0);   // the opening: middle and half-size
static const float2 kArchHalf = float2(135.0, 320.0);
static const float2 kCloak = float2(1180.0, 1170.0); // the hem of her cloak, blowing out left

float box(float2 q, float2 c, float2 h, float soft) {
    float2 d = abs(q - c) - h;
    return smoothstep(soft, -soft, max(d.x, d.y));
}

float4 mainImage(float2 fragCoord) {
    float t = iTime;
    float2 q = squarePoint(fragCoord, 0.95);

    // The forest beyond the arch stirs in the breeze (the ground and the arch itself stay put).
    float arch = box(q, kArch, kArchHalf, 12.0) * smoothstep(1010.0, 900.0, q.y);
    float2 breeze = float2(noise(q / 110.0 + float2(t * 0.35, 0.0)), noise(q / 110.0 + float2(4.0, t * 0.3))) - 0.5;
    q += breeze * 9.0 * arch;

    // Her cloak flutters, the loose hem most.
    float cloak = exp(-length((q - kCloak) / float2(130.0, 80.0)) * 1.6) * smoothstep(1100.0, 1150.0, q.y + 40.0);
    q.x += sin(q.y / 22.0 - t * 3.4) * 3.2 * cloak + sin(t * 1.3) * 3.0 * cloak;
    q.y += sin(q.x / 30.0 + t * 2.7) * 1.6 * cloak;

    // The cut-paper leaves along the top and right edges tremble.
    float lace = smoothstep(470.0, 300.0, q.y) * smoothstep(880.0, 980.0, q.x) + smoothstep(1640.0, 1700.0, q.x) * smoothstep(1000.0, 900.0, q.y) * (1.0 - arch);
    q += (float2(noise(q / 24.0 + float2(t * 0.9, 0.0)), noise(q / 24.0 + float2(2.0, t * 0.8))) - 0.5) * 3.0 * saturate(lace);

    float3 col = picture(q);
    float lum = dot(col, float3(0.3, 0.55, 0.15));
    float warmth = saturate((col.r - col.b) * 2.0);

    // The sun glows and its rays shimmer and turn slowly, spilling out of the arch down the stairs.
    float2 ds = q - kSun;
    float rs = length(ds);
    float ang = atan2(ds.y, ds.x);
    float rays = pow(noise(float2(ang * 9.0 + t * 0.05, t * 0.25)), 3.0) + 0.5 * pow(noise(float2(ang * 23.0 - t * 0.08, 3.0 + t * 0.4)), 4.0);
    float spill = max(arch, smoothstep(1700.0, 1000.0, q.y) * smoothstep(900.0, 1200.0, q.x) * smoothstep(1720.0, 1550.0, q.x) * 0.6);
    float pulse = 0.9 + 0.1 * sin(t * 0.7) + 0.04 * sin(t * 2.3);
    col += float3(1.0, 0.72, 0.35) * (rays * exp(-rs / 420.0) * 0.55 * spill + exp(-rs / 60.0) * 0.25) * pulse;

    // Dappled light over the stairs, as if through moving leaves.
    float stairs = box(q, float2(1250.0, 1290.0), float2(330.0, 240.0), 60.0) * warmth * smoothstep(0.35, 0.7, lum);
    col *= 1.0 + stairs * (fbm(q / 85.0 + float2(t * 0.12, -t * 0.05)) - 0.5) * 0.5;

    // Dust drifting in the sunbeam.
    float beam = smoothstep(1650.0, 900.0, q.y) * exp(-abs(q.x - lerp(1430.0, 1250.0, saturate((q.y - 700.0) / 800.0))) / 160.0);
    float2 p = q / kImg.y;
    float dust = motes(p, t, 0.03, 0.0011, 0.35, 5.0, 0.0006) + motes(p, t, 0.05, 0.0018, 0.25, 9.0, 0.0006) * 0.7;
    col += float3(1.0, 0.85, 0.55) * dust * beam * 0.6;
    return float4(col, 1.0);
}
