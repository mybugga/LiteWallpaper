// Planet, cosmic: a blue and violet world veined with molten orange, its rings streaming violet and blue. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_cosmic.jpg
// scale: 1

static const float3 kPlanet = float3(1240, 445, 250);       // picture pixels: centre, radius
static const float4 kRing = float4(1240, 445, -20.2, 725);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1065, 255);
static const float3 kFlareColor = float3(0.45, 0.65, 1.0);
static const float kRingSpeed = 0.05;  // radians per second at the outer edge
#include "planet.hlsli"
