// Planet, ice: an ice world ringed with glittering crystal shards, in teal frost clouds. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_ice.jpg
// scale: 1

static const float3 kPlanet = float3(1262, 420, 270);       // picture pixels: centre, radius
static const float4 kRing = float4(1262, 420, -17.8, 885);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1048, 258);
static const float3 kFlareColor = float3(0.45, 0.95, 1.0);
static const float kRingSpeed = 0.04;  // radians per second at the outer edge
#include "planet.hlsli"
