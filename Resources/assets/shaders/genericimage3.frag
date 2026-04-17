
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":0}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}

#include "common_pbr.h"
#include "common_blending.h"

uniform sampler2D g_Texture0; // {"label":"ui_editor_properties_albedo","nonremovable":true}

uniform mat4 g_ViewProjectionMatrix;
uniform vec4 g_Color4;

#if VERTEXCOLOR
varying vec4 v_Color;
#endif

#if PBRMASKS
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif

#if LIGHTING || REFLECTION
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal_map","combo":"NORMALMAP","format":"rg88","formatcombo":true,"mode":"normal","requireany":true,"require":{"LIGHTING":1,"REFLECTION":1}}
uniform sampler2D g_Texture2; // {"combo":"PBRMASKS","mode":"opacitymask","paintdefaultcolor":"0 0 0 1","components":[{"label":"ui_editor_properties_metallic_map","combo":"METALLIC_MAP"},{"label":"ui_editor_properties_roughness_map","combo":"ROUGHNESS_MAP"},{"label":"ui_editor_properties_reflection_map","combo":"REFLECTION_MAP"},{"label":"ui_editor_properties_emissive_map","combo":"EMISSIVE_MAP"}],"requireany":true,"require":{"LIGHTING":1,"REFLECTION":1}}
uniform float g_Roughness; // {"material":"roughness","label":"ui_editor_properties_roughness","default":0.7,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Metallic; // {"material":"metallic","label":"ui_editor_properties_metallic","default":0,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform vec3 g_SpecularTint; // {"material":"speculartint","label":"ui_editor_properties_specular_tint","type":"color","default":"1 1 1","group":"ui_editor_properties_material"}

uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 1 1","group":"ui_editor_properties_material"}
uniform float g_EmissiveBrightness; // {"material":"emissivebrightness", "label":"ui_editor_properties_emissive_brightness", "default":1.0,"range":[0,10],"group":"ui_editor_properties_material"}
#endif

#if LIGHTING
uniform vec3 g_LightAmbientColor;
#endif

#if LIGHTING || REFLECTION
varying vec4 v_ViewDir;
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
varying vec3 v_WorldPos;
#if NORMALMAP == 0
varying vec3 v_WorldNormal;
#endif
#endif

#if REFLECTION && NORMALMAP
uniform vec3 g_Screen;
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Texture3MipMapInfo;
#endif

#if REFLECTION && NORMALMAP || BLENDMODE
varying vec3 v_ScreenPos;
#endif

#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif

#if MORPHING || SKINNING_ALPHA
varying float v_VertexAlpha;
#endif

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
	vec4 color = texSample2D(g_Texture0, v_TexCoord.xy) * g_Color4;

#if LIGHTING || REFLECTION
	float metallic = g_Metallic;
	float roughness = g_Roughness;

#if PBRMASKS
	vec4 componentMaps = texSample2D(g_Texture2, v_TexCoord.zw);
#endif

#if METALLIC_MAP
	metallic = componentMaps.x;
#endif

#if ROUGHNESS_MAP
	roughness = componentMaps.y;
#endif

#if NORMALMAP
	vec2 compressedNormal = texSample2D(g_Texture1, v_TexCoord.xy).xy * 2.0 - 1.0;
	vec3 normal = vec3(compressedNormal,
		sqrt(saturate(1.0 - compressedNormal.x * compressedNormal.x - compressedNormal.y * compressedNormal.y)));
	normal = normalize(normal);
#else
	vec3 normal = normalize(v_WorldNormal);
#endif
#endif

#if LIGHTING || REFLECTION
#if SCENE_ORTHO
	// View vector should be static on puppets on 2D wallpapers
	vec3 normalizedViewVector = vec3(0, 0, 1);
#else
	vec3 normalizedViewVector = normalize(v_ViewDir.xyz);
#endif
	
#if NORMALMAP
	mat3 tangentSpace = mat3(v_Tangent, v_Bitangent, v_Normal);
	normal = mul(normal, tangentSpace);
#endif
#endif

#if LIGHTING
	vec3 f0 = CAST3(0.04);
	f0 = mix(f0, color.rgb, metallic);

	vec3 light = PerformLighting_Deprecated(v_WorldPos, color.rgb, normal, normalizedViewVector, g_SpecularTint, f0, roughness, metallic);
	vec3 ambient = g_LightAmbientColor * color.rgb;

#if EMISSIVE_MAP
	light = max(light, g_EmissiveColor * color.rgb * (componentMaps.a * g_EmissiveBrightness));
#endif

	color.rgb = CombineLighting(light, ambient);
#endif

#if REFLECTION && NORMALMAP || BLENDMODE
	vec2 screenUV = (v_ScreenPos.xy / v_ScreenPos.z) * 0.5 + 0.5;
#endif

#if REFLECTION && NORMALMAP
	float reflectivity = g_Reflectivity;

#if REFLECTION_MAP
	reflectivity *= componentMaps.z;
#endif

	vec2 tangent = normalize(v_Tangent.xy);
	vec2 bitangent = normalize(v_Bitangent.xy);

	float fresnelTerm = max(0.001, dot(normal, normalizedViewVector));
	normal = normalize(mul(normal, CAST3X3(g_ViewProjectionMatrix)));

#ifdef HLSL
	normal.y = -normal.y;
#endif

#if PLATFORM_ANDROID
	normal.xy = normal.xy * vec2(0.25 / g_Screen.z, 0.25);
#else
	// Make consistent on X since the width is usually more variable (multi monitors) - bad for phones tho
	normal.xy = normal.xy * vec2(0.15, 0.15 * g_Screen.z);
#endif
	//screenUV += normal * fresnelTerm;
	screenUV += normal.xy * pow(fresnelTerm, 4.0) * 4;

	vec3 reflectionColor = texSample2DLod(g_Texture3, screenUV, roughness * g_Texture3MipMapInfo).rgb;
	reflectionColor = reflectionColor * (1.0 - fresnelTerm) * reflectivity;
	reflectionColor = pow(max(CAST3(0.001), reflectionColor), CAST3(2.0 - metallic));

	color.rgb += saturate(reflectionColor) * fresnelTerm;
	//color.rgb = mix(color.rgb, vec3(screenUV, 0), 0.99);
#endif

#if HDR && (LIGHTING || REFLECTION) && EMISSIVE_MAP
	float emissiveOverbright = max(0.0, componentMaps.a * (g_EmissiveBrightness - 1.0));
	color.rgb += g_EmissiveColor * color.rgb * emissiveOverbright;
#endif

#if MORPHING || SKINNING_ALPHA
	color.a *= v_VertexAlpha;
#endif

#if VERTEXCOLOR
	color *= v_Color;
#endif

	gl_FragColor = color;

#if BLENDMODE
	vec4 screen = texSample2D(g_Texture4, screenUV);
	gl_FragColor.rgb = ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a);
	gl_FragColor.a = screen.a;
#endif

#if ALPHATOCOVERAGE
	gl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
