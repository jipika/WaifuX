
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":1}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}
// [COMBO] {"material":"ui_editor_properties_rim_lighting","combo":"RIMLIGHTING","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_toon_shading","combo":"SHADINGGRADIENT","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_tint_mask_in_alpha","combo":"TINTMASKALPHA","default":0}
// [COMBO_DISABLED] {"material":"ui_editor_properties_double_sided_lighting","combo":"DOUBLESIDEDLIGHTING","default":0}

#define RIM_LIGHTING_AMOUNT g_RimAmount
#define RIM_LIGHTING_EXPONENT g_RimExponent

uniform mat4 g_ViewProjectionMatrix;

#if SHADINGGRADIENT
#define GRADIENT_SAMPLER g_Texture4
uniform sampler2D g_Texture4; // {"label":"ui_editor_properties_shading_gradient","default":"gradient/gradient_toon_smooth","formatcombo":true,"nonremovable":true,"require":{"SHADINGGRADIENT":1}}
#endif
uniform float g_RimAmount; // {"material":"rimamount","label":"ui_editor_properties_rim_lighting_amount","default":2.0,"range":[0,5],"group":"ui_editor_properties_rim_lighting"}
uniform float g_RimExponent; // {"material":"rimexponent","label":"ui_editor_properties_rim_lighting_exponent","default":4.0,"range":[0.01,10],"group":"ui_editor_properties_rim_lighting"}

#include "common_fragment.h"
#include "common_pbr.h"

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

#if REFLECTION
uniform vec3 g_Screen;
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Texture3MipMapInfo;

varying vec3 v_ScreenPos;
#endif

uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 1 1","group":"ui_editor_properties_material"}
uniform float g_EmissiveBrightness; // {"material":"emissivebrightness", "label":"ui_editor_properties_emissive_brightness", "default":1.0,"range":[0,10],"group":"ui_editor_properties_material"}

#if LIGHTS_POINT
uniform vec4 g_LPoint_Color[LIGHTS_POINT];
uniform vec4 g_LPoint_Origin[LIGHTS_POINT];
#endif
#if LIGHTS_SPOT
uniform vec4 g_LSpot_Color[LIGHTS_SPOT];
uniform vec4 g_LSpot_Origin[LIGHTS_SPOT];
uniform vec4 g_LSpot_Direction[LIGHTS_SPOT];
#endif
#if LIGHTS_TUBE
uniform vec4 g_LTube_Color[LIGHTS_TUBE];
uniform vec4 g_LTube_OriginA[LIGHTS_TUBE];
uniform vec4 g_LTube_OriginB[LIGHTS_TUBE];
#endif
#if LIGHTS_DIRECTIONAL
uniform vec4 g_LDirectional_Color[LIGHTS_DIRECTIONAL];
uniform vec4 g_LDirectional_Direction[LIGHTS_DIRECTIONAL];
#endif

#if LIGHTING
#if SHADERVERSION < 62
// DEPRECATION BSSSSS
vec3 PerformLighting_Deprecated(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)
{
	vec3 light = CAST3(0);

#if LIGHTS_POINT
	for (uint l = 0u; l < CASTU(LIGHTS_POINT); ++l)
	{
		vec3 lightDelta = g_LPoint_Origin[l].xyz - worldPos;
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LPoint_Color[l].rgb, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_SPOT
	for (uint l = 0u; l < CASTU(LIGHTS_SPOT); ++l)
	{
		vec3 lightDelta = g_LSpot_Origin[l].xyz - worldPos;
		float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[l].xyz);
		spotCookie = smoothstep(g_LSpot_Direction[l].w, g_LSpot_Origin[l].w, spotCookie);
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LSpot_Color[l].rgb, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_TUBE
	for (uint l = 0u; l < CASTU(LIGHTS_TUBE); ++l)
	{
		vec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[l].xyz, g_LTube_OriginB[l].xyz);
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LTube_Color[l].rgb, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_DIRECTIONAL
	for (uint l = 0u; l < CASTU(LIGHTS_DIRECTIONAL); ++l)
	{
		light += ComputePBRLight(normal, g_LDirectional_Direction[l].xyz, viewVector, color, g_LDirectional_Color[l].rgb, ambient, roughness, metallic);
	}
#endif

	return light;
}

#else

vec3 PerformLighting_Deprecated(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)
{
	vec3 light = CAST3(0);

#if LIGHTS_POINT
	for (uint l = 0u; l < CASTU(LIGHTS_POINT); ++l)
	{
		vec3 lightDelta = g_LPoint_Origin[l].xyz - worldPos;
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LPoint_Color[l].rgb * g_LPoint_Color[l].w * g_LPoint_Color[l].w, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_SPOT
	for (uint l = 0u; l < CASTU(LIGHTS_SPOT); ++l)
	{
		vec3 lightDelta = g_LSpot_Origin[l].xyz - worldPos;
		float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[l].xyz);
		spotCookie = smoothstep(g_LSpot_Direction[l].w, g_LSpot_Origin[l].w, spotCookie);
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LSpot_Color[l].rgb * spotCookie * g_LSpot_Color[l].w * g_LSpot_Color[l].w, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_TUBE
	for (uint l = 0u; l < CASTU(LIGHTS_TUBE); ++l)
	{
		vec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[l].xyz, g_LTube_OriginB[l].xyz);
		light += ComputePBRLight(normal, lightDelta, viewVector, color, g_LTube_Color[l].rgb * g_LTube_Color[l].w * g_LTube_Color[l].w, ambient, roughness, metallic);
	}
#endif

#if LIGHTS_DIRECTIONAL
	for (uint l = 0u; l < CASTU(LIGHTS_DIRECTIONAL); ++l)
	{
		light += ComputePBRLight(normal, g_LDirectional_Direction[l].xyz, viewVector, color, g_LDirectional_Color[l].rgb * g_LDirectional_Color[l].w * g_LDirectional_Color[l].w, ambient, roughness, metallic);
	}
#endif

	return light;
}

#endif
#endif

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);

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
	light = PerformLighting_Deprecated(v_WorldPos, albedo.rgb, normal, normalizedViewVector, CAST3(1.0), f0, roughness, metallic);
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

	gl_FragColor = albedo;

#if ALPHATOCOVERAGE
	gl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
