// Shared by the *_clock wallpapers: the picture's own hands, lifted off it by
// scripts/make-clock-hands.py, show the real time of day here (iDate), the seconds hand ticking.
// Not a wallpaper itself (.hlsli files aren't listed).
//
// Before including: kImg (picture size), the numbers from <name>_hands.hlsli, and the textures:
// iChannel0 = the picture without its hands (<name>_plate.jpg), iChannel1 = the hands
// (<name>_hands.png, one tile per hand: hour, minute, second).
#include "space.hlsli"

float3 plate(float2 q) { return iChannel0.SampleLevel(iSampler, q / kImg, 0).rgb; }
float3 picture(float2 q) { return plate(q); }  // what fx.hlsli samples

// One hand at picture point q, turned from where it lay in the picture to `angle` (clock angle:
// 0 at twelve, clockwise): premultiplied colour and coverage.
float4 hand(float2 q, float tile, float angle, float pictureAngle) {
    float2 d = rot(q - kHub, pictureAngle - angle);
    float half = kTile * 0.5;
    if (abs(d.x) > half - 1.0 || abs(d.y) > half - 1.0) return 0;
    float2 uv = float2((tile * kTile + half + 0.5 + d.x) / (kTile * kHandCount), (half + 0.5 + d.y) / kTile);
    return iChannel1.SampleLevel(iSampler, uv, 0);
}

// The time of day in seconds (iDate.w), as hand angles: hour, minute, and the seconds hand stepping
// each second with a little overshoot and settle, like a quartz movement's.
float3 handAngles(float secs) {
    const float tau = 6.2831853;
    float tick = saturate(frac(secs) / 0.16) - 1.0;
    float ease = 1.0 + 2.70158 * tick * tick * tick + 1.70158 * tick * tick;  // ease-out-back
    float s = fmod(floor(secs), 60.0) - 1.0 + ease;
    return float3(frac(secs / 43200.0) * tau, frac(secs / 3600.0) * tau, s / 60.0 * tau);
}

// The dial at q with its three hands at the real time: their soft shadows first, then the hands
// bottom to top, then the cap (from the plate) over them all.
float3 clockFace(float2 q, float3 col, float secs, float2 shadowOffset, float shadowStrength) {
    float r = length(q - kHub);
    if (r > kDialR + 40.0) return col;
    float3 a = handAngles(secs);
    float shade = max(hand(q - shadowOffset, 0.0, a.x, kAngleHour).a,
                  max(hand(q - shadowOffset, 1.0, a.y, kAngleMinute).a, hand(q - shadowOffset * 1.3, 2.0, a.z, kAngleSecond).a));
    col *= 1.0 - shadowStrength * shade;
    float4 h = hand(q, 0.0, a.x, kAngleHour);
    col = h.rgb + (1.0 - h.a) * col;
    h = hand(q, 1.0, a.y, kAngleMinute);
    col = h.rgb + (1.0 - h.a) * col;
    h = hand(q, 2.0, a.z, kAngleSecond);
    col = h.rgb + (1.0 - h.a) * col;
    return lerp(col, plate(q), smoothstep(kCapR + 0.8, kCapR - 0.6, r));
}

// The picture point under fragCoord. Wide screens: the picture fills the screen (cropped to fit).
// Tall screens (PORTRAIT, phones): the whole subject fits across the screen, the picture's black
// background carrying on above and below; `subject` is the subject's middle and width in picture
// pixels. Returns the point and, in z, how much of it is inside the picture (0 off its edges).
float3 framePoint(float2 fragCoord, float3 subject) {
    float aspect = iResolution.x / iResolution.y;
#ifdef PORTRAIT
    // The phone shows a slice about 0.45 screens wide of this tall canvas; fit the subject to it.
    float scale = subject.z / (0.43 * iResolution.y);
    float2 q = subject.xy + float2(fragCoord.x - iResolution.x * 0.5, iResolution.y * 0.5 - fragCoord.y) * scale;
#else
    float px = 1.0 / iResolution.y;
    float2 p = fragCoord * px;
    float imgAspect = kImg.x / kImg.y;
    float2 fit = aspect > imgAspect ? float2(1.0, imgAspect / aspect) : float2(aspect / imgAspect, 1.0);
    float2 q = (0.5 + (float2(p.x / aspect, 1.0 - p.y) - 0.5) * fit) * kImg;
#endif
    float2 edge = min(q, kImg - q);
    return float3(q, saturate(min(edge.x, edge.y) / 40.0));
}
