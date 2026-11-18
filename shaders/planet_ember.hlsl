// Planet, ember: a burning world with fiery cracks and blazing orange rings, in drifting embers. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_ember.jpg
// scale: 1

static const float3 kPlanet = float3(1255, 445, 295);       // picture pixels: centre, radius
static const float4 kRing = float4(1255, 445, -19.3, 830);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1010, 262);
static const float3 kFlareColor = float3(1.0, 0.6, 0.25);
static const float kRingSpeed = 0.05;  // radians per second at the outer edge
#include "planet.hlsli"
