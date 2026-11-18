// Planet, neon: a violet world in neon magenta and blue rings, wrapped in purple nebula. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_neon.jpg
// scale: 1

static const float3 kPlanet = float3(1230, 445, 285);       // picture pixels: centre, radius
static const float4 kRing = float4(1230, 445, -19.3, 920);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(1005, 255);
static const float3 kFlareColor = float3(0.85, 0.4, 1.0);
static const float kRingSpeed = 0.05;  // radians per second at the outer edge
#include "planet.hlsli"
