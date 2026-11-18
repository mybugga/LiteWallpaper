// Planet, crystal: a cracked blue world ringed with tumbling ice crystals. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_crystal.jpg
// scale: 1

static const float3 kPlanet = float3(1250, 430, 280);       // picture pixels: centre, radius
static const float4 kRing = float4(1250, 430, -17.2, 910);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1040, 250);
static const float3 kFlareColor = float3(0.5, 0.75, 1.0);
static const float kRingSpeed = 0.04;  // radians per second at the outer edge
#include "planet.hlsli"
