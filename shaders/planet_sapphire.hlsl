// Planet, sapphire: a deep blue world with wide sapphire rings sweeping across the screen. A still picture brought to life (see planet.hlsli).
// texture: assets/planet_sapphire.jpg
// scale: 1

static const float3 kPlanet = float3(1240, 455, 330);       // picture pixels: centre, radius
static const float4 kRing = float4(1240, 455, -18.5, 1245);  // centre, angle (degrees), outer radius
static const float kRingRatio = 0.28;
static const float2 kFlare = float2(970, 295);
static const float3 kFlareColor = float3(0.45, 0.65, 1.0);
static const float kRingSpeed = 0.035;  // radians per second at the outer edge
#include "planet.hlsli"
