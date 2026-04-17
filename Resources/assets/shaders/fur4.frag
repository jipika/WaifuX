
// [PASS] shadow shadowcasterfur4
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":1}
// [COMBO] {"material":"ui_editor_properties_fog","combo":"FOG","default":1}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}
// [COMBO] {"material":"ui_editor_properties_rim_lighting","combo":"RIMLIGHTING","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_toon_shading","combo":"SHADINGGRADIENT","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_fur_quality","combo":"INSTANCECOUNT","default":5,"options":{"ui_editor_properties_low":5,"ui_editor_properties_medium":9,"ui_editor_properties_high":13,"ui_editor_properties_ultra":21}}

#define RIM_LIGHTING_AMOUNT g_RimAmount
#define RIM_LIGHTING_EXPONENT g_RimExponent

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

#include "base/model_fragment_v1.h"
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

varying vec4 v_WorldNormal;

#if LIGHTING || REFLECTION
#ifdef NORMALMAP
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
#endif
varying vec3 v_WorldPos;
#endif

varying vec2 v_TexCoord;
varying vec4 v_ViewDir;
varying vec3 v_LightAmbientColor;

#if REFLECTION
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Texture3MipMapInfo;

varying vec3 v_ScreenPos;
#endif

uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 1 1","group":"ui_editor_properties_material"}
uniform float g_EmissiveBrightness; // {"material":"emissivebrightness", "label":"ui_editor_properties_emissive_brightness", "default":1.0,"range":[0,10],"group":"ui_editor_properties_material"}

// <Fur additions
uniform sampler2D g_Texture8; // {"material":"fur","label":"ui_editor_properties_fur","default":"util/fur","formatcombo":true}

uniform float g_FurOcclusion; // {"material":"furocclusion","label":"ui_editor_properties_occlusion","default":0.1,"range":[0.0, 1.0],"group":"ui_editor_properties_fur"}
uniform float g_FurDetail; // {"material":"furdetail","label":"ui_editor_properties_detail","default":10.0,"range":[1.0, 30.0],"group":"ui_editor_properties_fur"}
// Fur additions>

#require LightingV1

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);

	albedo.rgb *= g_TintColor;

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
	vec3 normal = normalize(v_WorldNormal.xyz);
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
	albedo.rgb += ApplyReflection(MAKE_SAMPLER2D_ARGUMENT(g_Texture3), g_Texture3MipMapInfo, reflectivity, roughness, metallic, v_ScreenPos.xyz, normal, normalizedViewVector);
#endif

#if HDR
	albedo.rgb *= g_Brightness;

#if (LIGHTING || REFLECTION) && EMISSIVE_MAP
	float emissiveOverbright = max(0.0, componentMaps.a * (g_EmissiveBrightness - 1.0));
	albedo.rgb += g_EmissiveColor * albedo.rgb * emissiveOverbright;
#endif
#endif

	// <Fur additions
	float furDistance = v_WorldNormal.w;
	float furMask = ConvertTextureFormat(TEX8FORMAT, texSample2D(g_Texture8, v_TexCoord.xy * g_FurDetail)).a;
	float furOcclusion = max(1.0 - albedo.a, saturate(2.0 * furDistance));

	albedo.rgb *= saturate(max(1.0 - (furDistance - furMask), 1.0 - albedo.a));
	albedo.a = step(furDistance, furMask) * g_TintAlpha;
	albedo.rgb *= (1.0 - g_FurOcclusion) + furOcclusion * g_FurOcclusion;
	// Fur additions>

#if FOG_HEIGHT || FOG_DIST
	vec2 fogPixelState = CalculateFogPixelState(viewDist, v_ViewDir.w);
	albedo.rgb = ApplyFog(albedo.rgb, fogPixelState);
#if ADDITIVE
	albedo.a = ApplyFogAlpha(albedo.a, fogPixelState);
#endif
#endif

	gl_FragColor = albedo;

	ApplyAlphaToCoverage(gl_FragColor.a);
}
