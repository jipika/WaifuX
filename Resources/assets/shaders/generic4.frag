
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":1}
// [COMBO] {"material":"ui_editor_properties_fog","combo":"FOG","default":1}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}
// [COMBO] {"material":"ui_editor_properties_rim_lighting","combo":"RIMLIGHTING","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_toon_shading","combo":"SHADINGGRADIENT","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_tint_mask_in_alpha","combo":"TINTMASKALPHA","default":0}

#define RIM_LIGHTING_AMOUNT g_RimAmount
#define RIM_LIGHTING_EXPONENT g_RimExponent

uniform mat4 g_ViewProjectionMatrix;

#if SHADINGGRADIENT
#define GRADIENT_SAMPLER g_Texture4
uniform sampler2D g_Texture4; // {"label":"ui_editor_properties_shading_gradient","default":"gradient/gradient_toon_smooth","formatcombo":true,"nonremovable":true,"require":{"SHADINGGRADIENT":1}}
#endif
uniform float g_RimAmount; // {"material":"rimamount","label":"ui_editor_properties_rim_lighting_amount","default":2.0,"range":[0,5],"group":"ui_editor_properties_rim_lighting"}
uniform float g_RimExponent; // {"material":"rimexponent","label":"ui_editor_properties_rim_lighting_exponent","default":4.0,"range":[0.01,10],"group":"ui_editor_properties_rim_lighting"}

#if LIGHTS_SHADOW_MAPPING
#define SHADOW_ATLAS_SAMPLER g_Texture6
#define SHADOW_ATLAS_TEXEL g_Texture6Texel
uniform sampler2DComparison g_Texture6; // {"hidden":true,"default":"_rt_shadowAtlas"}
uniform vec4 g_Texture6Texel;
#endif

#if LIGHTS_COOKIE
#define COOKIE_SAMPLER g_Texture7
uniform sampler2D g_Texture7; // {"hidden":true,"default":"_alias_lightCookie"}
#endif

#include "common_fragment.h"
#include "common_pbr_2.h"
#include "common_fog.h"

uniform float g_Brightness; // {"material":"brightness","label":"ui_editor_properties_hdr_brightness","default":1,"range":[0,10]}

uniform vec3 g_TintColor; // {"material":"color","label":"ui_editor_properties_tint_color","type": "color", "default":"1 1 1"}
uniform float g_TintAlpha; // {"material":"alpha","label":"ui_editor_properties_opacity","default":1,"range":[0,1]}

uniform sampler2D g_Texture0; // {"material":"albedo","label":"ui_editor_properties_albedo","default":"util/white"}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal_map","format":"normalmap","formatcombo":true,"combo":"NORMALMAP"}
uniform sampler2D g_Texture2; // {"combo":"PBRMASKS","components":[{"label":"ui_editor_properties_metallic_map","combo":"METALLIC_MAP"},{"label":"ui_editor_properties_roughness_map","combo":"ROUGHNESS_MAP"},{"label":"ui_editor_properties_reflection_map","combo":"REFLECTION_MAP"},{"label":"ui_editor_properties_emissive_map","combo":"EMISSIVE_MAP"}]}

uniform float g_Roughness; // {"material":"roughness","label":"ui_editor_properties_roughness","default":0.7,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Metallic; // {"material":"metallic","label":"ui_editor_properties_metallic","default":0,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}

#if LIGHTING || REFLECTION
#ifdef NORMALMAP
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
#else
varying vec3 v_WorldNormal;
#endif
varying vec3 v_WorldPos;
#endif

varying vec2 v_TexCoord;
varying vec4 v_ViewDir;
varying vec3 v_LightAmbientColor;
//varying vec4 v_VertexColor;

#if REFLECTION
uniform vec3 g_Screen;
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Texture3MipMapInfo;

varying vec3 v_ScreenPos;
#endif

uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 1 1","group":"ui_editor_properties_material"}
uniform float g_EmissiveBrightness; // {"material":"emissivebrightness", "label":"ui_editor_properties_emissive_brightness", "default":1.0,"range":[0,10],"group":"ui_editor_properties_material"}

#require LightingV1

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy); // * v_VertexColor;

#if TINTMASKALPHA
	albedo.rgb = mix(albedo.rgb, CAST3(max(albedo.x, max(albedo.y, albedo.z))) * g_TintColor, albedo.a);
	albedo.a = 1.0;
#else
	albedo.rgb *= g_TintColor;
#endif
	albedo.a *= g_TintAlpha;

	float metallic = g_Metallic;
	float roughness = g_Roughness;

#if PBRMASKS
	vec4 componentMaps = texSample2D(g_Texture2, v_TexCoord.xy);
#endif

#if METALLIC_MAP
	metallic = componentMaps.x;
#endif

#if ROUGHNESS_MAP
	roughness = componentMaps.y;
#endif

	vec3 f0 = CAST3(0.04);
	f0 = mix(f0, albedo.rgb, metallic);

	float viewDist = length(v_ViewDir.xyz);
	vec3 normalizedViewVector = v_ViewDir.xyz / viewDist;

#if LIGHTING || REFLECTION
#if NORMALMAP
	vec3 normal = DecompressNormal(texSample2D(g_Texture1, v_TexCoord.xy));
	mat3 tangentSpace = mat3(v_Tangent, v_Bitangent, v_Normal);
	normal = mul(normal, tangentSpace);
#else
	vec3 normal = normalize(v_WorldNormal);
#endif
#endif

	vec3 light = CAST3(0.0);

#if LIGHTING
	light = PerformLighting_V1(v_WorldPos, albedo.rgb, normal, normalizedViewVector, CAST3(1.0), f0, roughness, metallic);
	vec3 ambient = v_LightAmbientColor * albedo.rgb;
#else
	vec3 ambient = albedo.rgb;
#endif

#if EMISSIVE_MAP
	light = max(light, g_EmissiveColor * albedo.rgb * (componentMaps.a * g_EmissiveBrightness));
#endif

	albedo.rgb = CombineLighting(light, ambient);

#if REFLECTION
	float reflectivity = g_Reflectivity;

#if REFLECTION_MAP
	reflectivity *= componentMaps.z;
#endif
	vec2 screenUV = (v_ScreenPos.xy / v_ScreenPos.z) * 0.5 + 0.5;

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

	vec3 reflectionColor = texSample2DLod(g_Texture3, screenUV, roughness * g_Texture3MipMapInfo).rgb * clipReflection;
	reflectionColor = reflectionColor * (1.0 - fresnelTerm) * reflectivity;
	reflectionColor = pow(max(CAST3(0.001), reflectionColor), CAST3(2.0 - metallic));

	albedo.rgb += saturate(reflectionColor);
#endif

#if HDR
	albedo.rgb *= g_Brightness;

#if (LIGHTING || REFLECTION) && EMISSIVE_MAP
	float emissiveOverbright = max(0.0, componentMaps.a * (g_EmissiveBrightness - 1.0));
	albedo.rgb += g_EmissiveColor * albedo.rgb * emissiveOverbright;
#endif
#endif

#if FOG_HEIGHT || FOG_DIST
	vec2 fogPixelState = CalculateFogPixelState(viewDist, v_ViewDir.w);
	albedo.rgb = ApplyFog(albedo.rgb, fogPixelState);
#if ADDITIVE
	albedo.a = ApplyFogAlpha(albedo.a, fogPixelState);
#endif
#endif

	gl_FragColor = albedo;

#if ALPHATOCOVERAGE
	gl_FragColor.a = saturate((gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5);
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
