
// [COMBO] {"material":"ui_editor_properties_fog","combo":"FOG","default":1}

#include "common_fog.h"
#include "common_pbr_2.h"

uniform mat4 g_AltModelMatrix;
uniform mat4 g_EffectModelMatrix;

#if SHADOW
uniform sampler2DComparison g_Texture0; // {"hidden":true,"default":"_rt_shadowAtlas"}
#endif

uniform sampler2DBackBuffer g_Texture1; // {"hidden":true,"default":"_rt_volumetricsBack"}
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_volumetricsSingle"}

#ifdef COOKIE
uniform sampler2D g_Texture2;
#endif

uniform vec4 g_RenderVar0;
uniform vec4 g_RenderVar1;
uniform vec4 g_RenderVar2;
uniform vec4 g_RenderVar3;
uniform vec4 g_RenderVar4;
uniform vec4 g_Texture1Resolution;
uniform vec4 g_Texture3Resolution;

#define VAR_SHADOWMAP_TRANSFORMS g_RenderVar0
#define VAR_SPOT_PARAMS g_RenderVar1
#define VAR_LIGHT_ORIGIN (g_RenderVar2.xyz)
#define VAR_SPOT_FORWARD (g_RenderVar3.xyz)
#define VAR_COLOR (g_RenderVar4.xyz)

#define VAR_DENSITY (g_RenderVar2.w)
#define VAR_EXPONENT (g_RenderVar4.w)

#define VAR_SPOT_PARAMS_RADIUS (VAR_SPOT_PARAMS.x)
#define VAR_SPOT_PARAMS_INNER (VAR_SPOT_PARAMS.y)
#define VAR_SPOT_PARAMS_OUTER (VAR_SPOT_PARAMS.z)
#define VAR_SPOT_PARAMS_INTENSITY (VAR_SPOT_PARAMS.w)

#define VAR_POINT_PARAMS_PROJECTION_INFO (g_RenderVar3)

varying vec4 v_ScreenPos;

#if FOG_DIST || FOG_HEIGHT
uniform vec3 g_EyePosition;
//varying vec2 v_FogParams;
#endif

float hash12(vec2 p)
{
	vec3 p3  = frac(vec3(p.xyx) * 43758.5453);
	p3 += CAST3(dot(p3, p3.yzx + 19.19));
	return frac((p3.x + p3.y) * p3.z);
}

void main() {
	vec3 screenUVDepth = (v_ScreenPos.xyz / v_ScreenPos.w);
	vec2 screenUV = screenUVDepth.xy * vec2(0.5, -0.5) + vec2(0.5, 0.5);

	float backDepth = texSample2DBackBuffer(g_Texture1, screenUV.xy, g_Texture1Resolution.xy).r;
	float limitDepth = texLoad2D(g_Texture3, screenUV.xy, g_Texture3Resolution.xy).r;

#if REVERSEDEPTH
	clip(screenUVDepth.z - backDepth);
	backDepth = max(backDepth, limitDepth);
#else
	clip(backDepth - screenUVDepth.z);
	backDepth = min(backDepth, limitDepth);
#endif

	vec3 screenUVDepthEnd = vec3(screenUVDepth.x, screenUVDepth.y, backDepth);
	vec3 screenUVDepthLimit = vec3(screenUVDepth.x, screenUVDepth.y, limitDepth);

#if SHADOW || COOKIE
#if QUALITY == 4
	const float sampleCount = 64.0;
#elif QUALITY == 3
	const float sampleCount = 32.0;
#elif QUALITY == 2
	const float sampleCount = 24.0;
#else
	const float sampleCount = 12.0;
#endif
#else
#if QUALITY == 4
	const float sampleCount = 8.0;
#elif QUALITY == 3
	const float sampleCount = 5.0;
#elif QUALITY == 2
	const float sampleCount = 3.0;
#else
	const float sampleCount = 2.0;
#endif
#endif

#ifdef COOKIE
	vec3 shadowFactor = CAST3(0.0);
#else
	float shadowFactor = 0.0;
#endif

	vec4 worldStart = mul(vec4(screenUVDepth, 1.0), g_EffectModelMatrix);
	vec4 worldEnd = mul(vec4(screenUVDepthEnd, 1.0), g_EffectModelMatrix);
	vec4 worldLimit = mul(vec4(screenUVDepthLimit, 1.0), g_EffectModelMatrix);

	worldStart.xyz /= worldStart.w;
	worldEnd.xyz /= worldEnd.w;
	worldLimit.xyz /= worldLimit.w;

	vec3 worldStep = (worldEnd.xyz - worldStart.xyz) / CAST3(sampleCount + 1.0);

	float maxLightScale = VAR_SPOT_PARAMS_INTENSITY;
	float invRadius = 1.0 / VAR_SPOT_PARAMS_RADIUS;

#if POINTLIGHT
	maxLightScale *= length(worldEnd.xyz - worldStart.xyz) * invRadius * 0.5;
#else
	maxLightScale *= length(worldEnd.xyz - worldStart.xyz) * invRadius;
#endif

#if SHADOW
	worldStart.xyz += worldStep * hash12(screenUV);
#endif

	for (uint s = 0u; s < sampleCount; ++s)
	{
		worldStart.xyz += worldStep;
		vec3 lightDelta = worldStart.xyz - VAR_LIGHT_ORIGIN;
		float radiusFalloff = pow(saturate(1.0 - (length(lightDelta) * invRadius)), VAR_EXPONENT);

#if COOKIE
		float spotCookie = 1.0;
#elif POINTLIGHT
		float spotCookie = 1.0;
#else
		float spotCookie = dot(normalize(lightDelta), VAR_SPOT_FORWARD);
		spotCookie = smoothstep(VAR_SPOT_PARAMS_OUTER, VAR_SPOT_PARAMS_INNER, spotCookie);
#endif

#if POINTLIGHT
		vec4 uvs = CalculateProjectedCoordsPoint(worldStart.xyz, VAR_LIGHT_ORIGIN, VAR_POINT_PARAMS_PROJECTION_INFO, VAR_SHADOWMAP_TRANSFORMS);
#else
		vec4 uvs = mul(vec4(worldStart.xyz, 1.0), g_AltModelMatrix);

		// Increase UV to hide border inconsistencies due to different buffer sizes
		uvs.xyz /= uvs.w;
		uvs.xy = uvs.xy * vec2(0.525, -0.525) + CAST2(0.5);
#endif

#ifdef COOKIE
		vec3 cookieColor = texSample2D(g_Texture2, uvs.xy).rgb;
#endif

#if SHADOW
#if POINTLIGHT
		float shadowSample = texSample2DCompare(g_Texture0, uvs.xy, uvs.z).r * radiusFalloff;
#else
		uvs.xy *= VAR_SHADOWMAP_TRANSFORMS.zw;
		uvs.xy += VAR_SHADOWMAP_TRANSFORMS.xy;

		float shadowSample = texSample2DCompare(g_Texture0, uvs.xy, uvs.z).r * radiusFalloff * spotCookie;
#endif
#else
		float shadowSample = radiusFalloff * spotCookie;
#endif

#if FOG_HEIGHT || FOG_DIST
		vec3 viewDir = g_EyePosition - worldStart.xyz;

		vec2 fogPixelState = CalculateFogPixelState(length(viewDir), worldStart.y);
		shadowSample *= ApplyFogAlpha(shadowSample, fogPixelState);
#endif

#ifdef COOKIE
		shadowFactor += shadowSample * cookieColor;
#else
		shadowFactor += shadowSample;
#endif
	}

#ifdef COOKIE
	shadowFactor /= CAST3(sampleCount);
#else
	shadowFactor /= sampleCount;
#endif

	gl_FragColor.rgb = VAR_DENSITY * maxLightScale * shadowFactor * VAR_COLOR * 0.1;
	gl_FragColor.a = 1;
}