
#include "common.h"

vec3 FresnelSchlick(float lightTheta, vec3 baseReflectance)
{
	return baseReflectance + (1.0 - baseReflectance) * pow(max(1.0 - lightTheta, 0.001), 5.0);
}

vec3 PointSegmentDelta(vec3 pos, vec3 segmentA, vec3 segmentB)
{
	vec3 delta = segmentB - segmentA;
	float v = dot(delta, delta);
	if (v == 0.0)
		return segmentA - pos;
	return segmentA + saturate(dot(pos - segmentA, segmentB - segmentA) / v) * (segmentB - segmentA) - pos;
}

float Distribution_GGX(vec3 N, vec3 H, float roughness)
{
	float rSqr = roughness * roughness;
	float rSqr2 = rSqr * rSqr;
	float NH = max(dot(N, H), 0.0);
	float denominator = (NH * NH * (rSqr2 - 1.0) + 1.0);
	return rSqr2 / (M_PI * denominator * denominator);
}

float Schlick_GGX(float NV, float roughness)
{
	float roughnessBase = roughness + 1.0;
	float roughnessScaled = (roughnessBase * roughnessBase) / 8.0;
	return NV / (NV * (1.0 - roughnessScaled) + roughnessScaled);
}

float GeoSmith(vec3 N, vec3 V, vec3 L, float roughness)
{
	return Schlick_GGX(max(dot(N, V), 0.001), roughness) * Schlick_GGX(max(dot(N, L), 0.001), roughness);
}

// L = worldToLightVector, N = normalVector, V = worldToViewVector
vec3 ComputePBRLight(vec3 N, vec3 L, vec3 V,
	vec3 albedo, vec3 lightColor, vec3 baseReflectance, float roughness, float metallic)
{
	float distance = length(L);
	L = L / distance;
	vec3 H = normalize(V + L);

	float NDF = Distribution_GGX(N, H, roughness);
	float G = GeoSmith(N, V, L, roughness);
	vec3 F = FresnelSchlick(max(dot(H, V), 0.0), baseReflectance);
	vec3 numerator = NDF * G * F;

	float dNL = dot(N, L);

#ifdef GRADIENT_SAMPLER
	vec3 NL = CAST3(max(dNL * 0.5 + 0.5, 0.0));
#if TEX4FORMAT == FORMAT_R8 || TEX4FORMAT == FORMAT_RG88
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rrr;
#else
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rgb;
#endif

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL.x * step(0.01, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, CAST3(rimTerm));
	metallic -= saturate(rimTerm);
#endif
	vec3 denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, CAST3(0.001));
#else
	float NL = max(dNL, 0.0);

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL * step(0.01, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, rimTerm);
	metallic -= saturate(rimTerm);
#endif
	float denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, 0.001);
#endif

	vec3 diffuse = (1.0 - metallic) * (CAST3(1.0) - F);
	vec3 radiance = lightColor.xyz / (distance * distance);
	return (diffuse * albedo / M_PI + specular) * radiance * NL;
}

vec3 CombineLighting(vec3 light, vec3 ambient)
{
#if HDR
	float lightLen = length(light);
	float overbright = (saturate(lightLen - 2.0) * 0.5) / max(0.01, lightLen);
	return saturate(ambient + light) + (light * overbright);
#else
	return ambient + light;
#endif
}
