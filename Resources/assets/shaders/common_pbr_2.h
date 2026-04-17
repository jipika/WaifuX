
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

#ifdef SHADOW_ATLAS_SAMPLER
#define SHADOW_ATLAS_ANTIALIAS 0
#if SHADOW_ATLAS_ANTIALIAS
float random(vec2 p){return frac(cos(dot(p,vec2(23.14069263277926,2.665144142690225)))*12345.6789);}
#endif
float PerformShadowMapping(vec3 projectedCoords, vec4 atlasTransform)
{
	projectedCoords.xy *= atlasTransform.zw;
	projectedCoords.xy += atlasTransform.xy;

#if SHADOW_ATLAS_ANTIALIAS
	vec2 scaled = projectedCoords.xy * SHADOW_ATLAS_TEXEL.zw;
	vec2 fr = frac(scaled);
	vec4 boundsLowHigh = vec4(scaled - fr, 0, 0);
	boundsLowHigh.zw = boundsLowHigh.xy + CAST2(1.0);
	
	vec4 rands = vec4(random(boundsLowHigh.xy), random(boundsLowHigh.zy), random(boundsLowHigh.xw), random(boundsLowHigh.zw));
	vec2 interpRandX = mix(rands.xy, rands.zw, fr.y);
	float interpRand = mix(interpRandX.x, interpRandX.y, fr.x);
	
	vec2 offsets = CAST2(interpRand) * SHADOW_ATLAS_TEXEL.xy;
#else
	vec2 offsets = SHADOW_ATLAS_TEXEL.xy;
#endif

	//return texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy, projectedCoords.z).r;

	//return (
	//		texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy - offsets, projectedCoords.z).r +
	//		texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(offsets.x, -offsets.y), projectedCoords.z).r +
	//		texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(-offsets.x, offsets.y), projectedCoords.z).r +
	//		texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + offsets.x, projectedCoords.z).r
	//		)
	//		/ 4.0;

#if LIGHTS_SHADOW_MAPPING_QUALITY == 1
	return texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy, projectedCoords.z).r;
#else
	vec2 roundOffset = offsets * CAST2(0.81616);
	offsets *= CAST2(1.02323);
	return (
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy - roundOffset, projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(0, -offsets.y), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(roundOffset.x, -roundOffset.y), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(-offsets.x, 0), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy, projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(offsets.x, 0), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(-roundOffset.x, roundOffset.y), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + vec2(0, offsets.y), projectedCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, projectedCoords.xy + roundOffset, projectedCoords.z).r
			)
			/ 9.0;
#endif
}

float PerformPointShadowMapping(vec4 shadowMapCoords)
{
#if LIGHTS_SHADOW_MAPPING_QUALITY == 1
	return texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy, shadowMapCoords.z).r;
#else
	vec2 offsets = SHADOW_ATLAS_TEXEL.xy;
	vec2 roundOffset = offsets * CAST2(0.81616);
	offsets *= CAST2(1.02323);
	return (
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy - roundOffset, shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(0, -offsets.y), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(roundOffset.x, -roundOffset.y), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(-offsets.x, 0), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy, shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(offsets.x, 0), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(-roundOffset.x, roundOffset.y), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + vec2(0, offsets.y), shadowMapCoords.z).r +
			texSample2DCompare(SHADOW_ATLAS_SAMPLER, shadowMapCoords.xy + roundOffset, shadowMapCoords.z).r
			)
			/ 9.0;
#endif
}
#endif

vec3 CalculateProjectedCoords(vec3 worldPos, mat4 shadowViewProjection)
{
	vec4 proj = mul(vec4(worldPos, 1.0), shadowViewProjection);
	proj.xyz /= proj.w;

	proj.xy = proj.xy * vec2(0.5, -0.5) + CAST2(0.5);

	// step(proj.w, 0.0) to identify behind projection
	proj.y = mix(proj.y, 2.0, step(proj.w, 0.0));

	return proj.xyz;
}

vec4 CalculateProjectedCoordsCascades(vec3 worldPos, mat4 shadowViewProjection)
{
	vec4 proj = mul(vec4(worldPos, 1.0), shadowViewProjection);
	proj.xyz /= proj.w;

	// Disable shadow outside bounds
#if REVERSEDEPTH
	proj.w = step(1.0, dot(CAST3(1.0), vec3(step(0.99, abs(proj.xy)), step(proj.z, 0.01))));
#else
	proj.w = step(1.0, dot(CAST3(1.0), step(0.99, abs(proj.xyz))));
#endif

	proj.xy = proj.xy * CAST2(0.5) + CAST2(0.5);
	proj.y = 1.0 - proj.y;

	return proj;
}

vec4 CalculateProjectedCoordsPoint(vec3 worldPos, vec3 lightOrigin, vec4 projectionInfo, vec4 atlasTransform)
{
	vec3 lightDelta = worldPos - lightOrigin;
	vec3 lightDeltaAbs = abs(lightDelta);
	vec2 viewportScale = vec2(0.5, 0.3333);

#if LIGHTS_SHADOW_MAPPING_QUALITY == 2 || LIGHTS_SHADOW_MAPPING_QUALITY == 1
	vec2 viewportPointCompensation = vec2(0.47, -0.47);
#elif LIGHTS_SHADOW_MAPPING_QUALITY == 3
	vec2 viewportPointCompensation = vec2(0.48, -0.48);
#else
	vec2 viewportPointCompensation = vec2(0.49, -0.49);
#endif

	vec2 viewportOffset;
	vec2 viewportOffsetSteps = atlasTransform.zw * viewportScale;
	mat4 viewMatrix;

	if (lightDeltaAbs.x >= lightDeltaAbs.y && lightDeltaAbs.x >= lightDeltaAbs.z)
	{
		if (lightDelta.x >= 0.0)
		{
			viewMatrix = mat4(
				0, 0, -1, 0,
				0, 1, 0, 0,
				1, 0, 0, 0,
				-lightOrigin.z, -lightOrigin.y, lightOrigin.x, 1
			);
			viewportOffset = vec2(0.0, 0.0);
		}
		else
		{
			viewMatrix = mat4(
				0, 0, 1, 0,
				0, 1, 0, 0,
				-1, 0, 0, 0,
				lightOrigin.z, -lightOrigin.y, -lightOrigin.x, 1
			);
			viewportOffset = vec2(viewportOffsetSteps.x, 0.0);
		}
	}
	else if (lightDeltaAbs.y >= lightDeltaAbs.x && lightDeltaAbs.y >= lightDeltaAbs.z)
	{
		if (lightDelta.y >= 0.0)
		{
			viewMatrix = mat4(
				1, 0, 0, 0,
				0, 0, -1, 0,
				0, 1, 0, 0,
				-lightOrigin.x, -lightOrigin.z, lightOrigin.y, 1
			);
			viewportOffset = vec2(0.0, viewportOffsetSteps.y);
		}
		else
		{
			viewMatrix = mat4(
				1, 0, 0, 0,
				0, 0, 1, 0,
				0, -1, 0, 0,
				-lightOrigin.x, lightOrigin.z, -lightOrigin.y, 1
			);
			viewportOffset = vec2(viewportOffsetSteps.x, viewportOffsetSteps.y);
		}
	}
	else
	{
		if (lightDelta.z >= 0.0)
		{
			viewMatrix = mat4(
				-1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, -1, 0,
				lightOrigin.x, -lightOrigin.y, lightOrigin.z, 1
			);
			viewportOffset = vec2(0.0, viewportOffsetSteps.y * 2);
		}
		else
		{
			viewMatrix = mat4(
				1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, 1, 0,
				-lightOrigin.x, -lightOrigin.y, -lightOrigin.z, 1
			);
			viewportOffset = vec2(viewportOffsetSteps.x, viewportOffsetSteps.y * 2);
		}
	}

	mat4 project = mat4(
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, projectionInfo.x, projectionInfo.z,
		0, 0, projectionInfo.y, projectionInfo.w
	);

	vec4 projectedCoords = mul(mul(vec4(worldPos, 1.0), viewMatrix), project);
	projectedCoords.xyz /= projectedCoords.w;

	projectedCoords.xy = projectedCoords.xy	* viewportPointCompensation + CAST2(0.5);
	projectedCoords.y = mix(projectedCoords.y, 2.0, step(projectedCoords.w, 0.0));

	projectedCoords.xy *= atlasTransform.zw * viewportScale;
	projectedCoords.xy += atlasTransform.xy + viewportOffset;
	return projectedCoords;
}

// L = worldToLightVector, N = normalVector, V = worldToViewVector
vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,
	float radius, float exponent, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor)
{
	float distance = length(L);
	L = L / distance;
	vec3 H = normalize(V + L);

	float falloff = saturate(1.0 - distance / radius);
	// Ensure x > 0 && y >= 0 to avoid undefined behavior
#if HLSL
	vec3 radiance = lightColor * pow(falloff + 1.17549435e-38, exponent);
#else
	float flt_min = 6.103515625e-5;
	vec3 radiance = lightColor * mix(0.0, pow(falloff + flt_min, exponent), step(0.0, falloff - flt_min));
#endif

	float NDF = shadowFactor * Distribution_GGX(N, H, roughness);
	float G = GeoSmith(N, V, L, roughness);
	vec3 F = FresnelSchlick(max(dot(H, V), 0.0), baseReflectance);
	vec3 numerator = NDF * G * F;

	vec3 diffuse = (1.0 - metallic) * (CAST3(1.0) - F);
	float dNL = dot(N, L);

#if DOUBLESIDEDLIGHTING
	dNL = abs(dNL);
#endif

#ifdef GRADIENT_SAMPLER
	vec3 NL = CAST3(max(min(shadowFactor, dNL) * 0.5 + 0.5, 0.0));
#if TEX4FORMAT == FORMAT_R8 || TEX4FORMAT == FORMAT_RG88
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rrr;
#else
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rgb;
#endif

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = shadowFactor * pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL.x * step(0.001, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, CAST3(rimTerm));
	metallic -= saturate(rimTerm);
#endif
	vec3 denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, CAST3(0.001));
#else
	float NL = max(dNL * shadowFactor, 0.0);

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = shadowFactor * pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL * step(0.001, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, rimTerm);
	metallic -= saturate(rimTerm);
#endif
	float denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, 0.001);
#endif

	return (diffuse * albedo / M_PI + specular * specularTint) * radiance * NL;
}

// L = worldToLightVector, N = normalVector, V = worldToViewVector
vec3 ComputePBRLightShadowInfinite(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,
	vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor)
{
	vec3 H = normalize(V + L);
	float NDF = shadowFactor * Distribution_GGX(N, H, roughness);
	float G = GeoSmith(N, V, L, roughness);
	vec3 F = FresnelSchlick(max(dot(H, V), 0.0), baseReflectance);
	vec3 numerator = NDF * G * F;

	float dNL = dot(N, L);

#if DOUBLESIDEDLIGHTING
	dNL = abs(dNL);
#endif

#ifdef GRADIENT_SAMPLER
	vec3 NL = CAST3(max(min(shadowFactor, dNL) * 0.5 + 0.5, 0.0));
#if TEX4FORMAT == FORMAT_R8 || TEX4FORMAT == FORMAT_RG88
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rrr;
#else
	NL = texSample2D(GRADIENT_SAMPLER, vec2(NL.x, 0.0)).rgb;
#endif

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = shadowFactor * pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL.x * step(0.001, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, CAST3(rimTerm));
	metallic -= saturate(rimTerm);
#endif
	vec3 denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, CAST3(0.001));
#else
	float NL = max(dNL * shadowFactor, 0.0);

#if RIMLIGHTING
	float rimTerm = 1.0 - max(dot(N, V), 0.0);
	rimTerm = shadowFactor * pow(rimTerm, RIM_LIGHTING_EXPONENT) * RIM_LIGHTING_AMOUNT * NL * step(0.001, lightColor.x + lightColor.y + lightColor.z);
	NL = max(NL, rimTerm);
	metallic -= saturate(rimTerm);
#endif
	float denominator = 4.0 * max(dot(N, V), 0.0) * NL;
	vec3 specular = numerator / max(denominator, 0.001);
#endif

	vec3 diffuse = (1.0 - metallic) * (CAST3(1.0) - F);
	return (diffuse * albedo / M_PI + specular * specularTint) * lightColor * NL;
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

vec3 CombineLighting(vec3 light, vec3 baseAmbient, vec3 ambient)
{
#if HDR
	float lightLen = length(light);
	float overbright = (saturate(lightLen - 2.0) * 0.5) / max(0.01, lightLen);
	return max(baseAmbient, saturate(ambient + light)) + (light * overbright);
#else
	return max(baseAmbient, ambient + light);
#endif
}
