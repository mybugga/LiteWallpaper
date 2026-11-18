// Planet, storm: a blue world with a great spiral storm, ringed in electric blue. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_storm.jpg
// scale: 1

static const float3 kPlanet = float3(1225, 455, 340);       // picture pixels: centre, radius
static const float4 kRing = float4(1225, 455, -16.2, 880);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(955, 285);
static const float3 kFlareColor = float3(0.45, 0.7, 1.0);
static const float kRingSpeed = 0.04;  // radians per second at the outer edge
#include "planet.hlsli"
