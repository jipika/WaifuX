
#include "common_fragment.h"

uniform mat4 g_ViewProjectionMatrix;
uniform vec3 g_Screen;

#if REFLECTION
vec3 ApplyReflection(DECLARE_SAMPLER2D_PARAMETER(reflectionTexture), float reflectionTextureMipMapInfo, float reflectivity, float roughness, float metallic, vec3 screenPos, vec3 normal, vec3 normalizedViewVector)
{
#if REFLECTION_MAP
	reflectivity *= componentMaps.z;
#endif
	vec2 screenUV = (screenPos.xy / screenPos.z) * 0.5 + 0.5;

	float fresnelTerm = abs(dot(normal, normalizedViewVector));
	normal = normalize(mul(normal, CAST3X3(g_ViewProjectionMatrix)));

#ifdef HLSL
	normal.y = -normal.y;
#endif

#if PLATFORM_ANDROID
	normal.xy = normal.xy * vec2(0.20 / g_Screen.z, 0.20);
#else
	// Make consistent on X since the width is usually more variable (multi monitors) - bad for phones tho
	normal.xy = normal.xy * vec2(0.15, 0.15 * g_Screen.z);
#endif
	screenUV += normal.xy * pow(fresnelTerm, 4.0) * 10;
	float clipReflection = smoothstep(1.3, 1.0, screenUV.x) * smoothstep(-0.3, 0.0, screenUV.x) *
		smoothstep(1.3, 1.0, screenUV.y) * smoothstep(-0.3, 0.0, screenUV.y);

	vec3 reflectionColor = texSample2DLod(reflectionTexture, screenUV, roughness * reflectionTextureMipMapInfo).rgb * clipReflection;
	reflectionColor = reflectionColor * (1.0 - fresnelTerm) * reflectivity;
	reflectionColor = pow(max(CAST3(0.001), reflectionColor), CAST3(2.0 - metallic));

	return saturate(reflectionColor);
}
#endif

void ApplyAlphaToCoverage(inout float alpha)
{
#if ALPHATOCOVERAGE
	alpha = saturate((alpha - 0.5) / max(fwidth(alpha), 0.0001) + 0.5);
#if GLSL
	if (alpha < 0.5) discard;
#endif
#endif
}
