// Astronaut, pulsar: the astronaut faces the Crab Nebula, the wreck of a star that exploded in 1054,
// with the pulsar it left spinning at its heart (NASA/CXC/SAO, STScI, JPL-Caltech composite). The
// pulsar flashes as its beams sweep past, lighting the gas; the pulse shows in the visor too.
// texture: assets/astronaut_pulsar.png
// texture1: assets/space_pulsar.jpg
// scale: 1
#include "space.hlsli"

static const float2 kPulsarUV = float2(0.481, 0.650);       // the pulsar in the nebula photo
static const float2 kPulsarAt = float2(0.86, 0.50);         // where it sits on screen
static const float kHeight = 1.15;
static const float2 kVisorCoreUV = float2(0.7913, 0.1881);  // its reflection in the visor
static const float kSpin = 0.9;                             // radians per second
static const float kIncline = 1.1;                          // tilt of the spin axis toward us

// Beam direction in 3D: .xy on screen, .z toward the viewer.
float3 beamDir(float t) {
    float a = t * kSpin;
    float3 b = float3(cos(a), sin(a) * cos(kIncline), sin(a) * sin(kIncline));
    return float3(rot(b.xy, 0.5), b.z);
}

float flashAt(float t) { return pow(abs(beamDir(t).z), 14.0); }

float3 sky(float2 p, float px, float t, float aspect) {
    float angle = 0.08 * sin(t * 0.006);
    float3 neb = backdrop(backdropUV(p, kPulsarAt, kPulsarUV, kHeight, angle, t));
    // Lean the colours toward the visor's magenta and violet.
    neb *= float3(1.08, 0.86, 1.12);
    neb.r += neb.b * 0.12;

    // The pulsar moves with the drifting photo.
    float2 v = p - backdropToScreen(kPulsarUV, kPulsarAt, kPulsarUV, kHeight, angle, t);
    float r = length(v);

    // Two opposite beams sweeping round; the gas they cross lights up.
    float3 b = beamDir(t);
    float2 u = normalize(b.xy);
    float len = length(b.xy) * 0.7 + 0.05;
    float along = dot(v, u), across = abs(v.x * u.y - v.y * u.x);
    float beam = exp(-across / (0.002 + abs(along) * 0.06)) * exp(-abs(along) / (len * 0.4));
    float flash = flashAt(t);
    float3 col = neb * (0.85 + 1.4 * beam + 0.35 * flash * exp(-r / 0.25));
    col += float3(1.0, 0.6, 1.0) * beam * 0.25;
    float core = exp(-r * r / (2.0 * px * px * 2.5)) + exp(-r / 0.01) * 0.25;
    col += float3(1.0, 0.8, 1.0) * core * (0.4 + 1.5 * flash);

    col += starField(p, px, t, 0.0);
    col += shootingStar(p, aspect, t, px, float3(1.0, 0.85, 1.0));
    return col * vignette(p, aspect);
}

float4 mainImage(float2 fragCoord) {
    float px = 1.0 / iResolution.y, aspect = iResolution.x / iResolution.y;
    float2 p = fragCoord * px;
    float t = iTime;
    float2 size;
    float4 photo = samplePhoto(p, aspect, t, size);
    float3 col = photo.a < 0.995 ? sky(p, px, t, aspect) : 0;
    col = col * (1.0 - photo.a) + photo.rgb;
    col += visorFlare(p, photoToScreen(kVisorUV, size, aspect), px, t, float3(1.0, 0.35, 0.85));
    float rc = length(p - photoToScreen(kVisorCoreUV, size, aspect));
    col += float3(1.0, 0.5, 1.0) * flashAt(t) * (exp(-rc / 0.006) * 0.6 + exp(-rc / 0.03) * 0.15);
    col += suitLights(p, size, aspect, px, t);
    return float4(col, 1.0);
}
