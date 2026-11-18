// Planet, eclipse: a dark world eclipsing its star, the corona flaring gold behind it. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_eclipse.jpg
// scale: 1

static const float3 kPlanet = float3(1300, 470, 275);       // picture pixels: centre, radius
static const float4 kRing = float4(1300, 470, -16.8, 815);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1020, 345);
static const float3 kFlareColor = float3(1.0, 0.65, 0.25);
static const float kRingSpeed = 0.04;  // radians per second at the outer edge
#define HAS_CORONA
static const float3 kCorona = float3(1240, 420, 300);  // the eclipsed star: centre, radius
#include "planet.hlsli"
