
#include "common_pbr.h"
#include "common_blending.h"

uniform sampler2D g_Texture0; // {"label":"ui_editor_properties_albedo","nonremovable":true}

#ifndef VERSION
uniform float g_Brightness; // {"material":"Brightness","label":"ui_editor_properties_brightness","default":1,"range":[0,2]}
uniform float g_UserAlpha; // {"material":"Alpha","label":"ui_editor_properties_alpha","default":1,"range":[0,1]}
#else
uniform vec4 g_Color4;
#endif

#if PBRMASKS
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif

#if LIGHTING || REFLECTION
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal_map","combo":"NORMALMAP","format":"rg88","formatcombo":true,"mode":"normal","requireany":true,"require":{"LIGHTING":1,"REFLECTION":1}}
uniform sampler2D g_Texture2; // {"combo":"PBRMASKS","mode":"opacitymask","paintdefaultcolor":"0 0 0 1","components":[{"label":"ui_editor_properties_metallic_map","combo":"METALLIC_MAP"},{"label":"ui_editor_properties_roughness_map","combo":"ROUGHNESS_MAP"},{"label":"ui_editor_properties_reflection_map","combo":"REFLECTION_MAP"},{"label":"ui_editor_properties_emissive_map","combo":"EMISSIVE_MAP"}],"requireany":true,"require":{"LIGHTING":1,"REFLECTION":1}}
uniform float g_Roughness; // {"material":"roughness","label":"ui_editor_properties_roughness","default":0.5,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Metallic; // {"material":"metallic","label":"ui_editor_properties_metallic","default":0.5,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}

uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 1 1","group":"ui_editor_properties_material"}
uniform float g_EmissiveBrightness; // {"material":"emissivebrightness", "label":"ui_editor_properties_emissive_brightness", "default":1.0,"range":[0,10],"group":"ui_editor_properties_material"}
#endif

#if LIGHTING
uniform vec4 g_LightsColorPremultiplied[3];
uniform vec3 g_LightAmbientColor;

varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;
#endif

// Local space normal direction and precomputed tangent space in light vectors
#if (LIGHTING || REFLECTION) && NORMALMAP == 0
// World space normal direction without normal map
varying vec3 v_Normal;
#endif

#if REFLECTION && NORMALMAP
uniform vec3 g_Screen;
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_Texture3MipMapInfo;

varying vec3 v_Tangent;
varying vec3 v_Bitangent;
varying vec3 v_ScreenPos;
#endif

#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
varying vec3 v_ScreenCoord;
#endif

#ifdef SKINNING_ALPHA
varying float v_BoneAlpha;
#endif

void main() {
	vec4 color = texSample2D(g_Texture0, v_TexCoord.xy);

#ifndef VERSION
	color.rgb *= g_Brightness;
	color.a *= g_UserAlpha;
#else
	color *= g_Color4;
#endif

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
	vec3 normal = normalize(v_Normal);
#endif
#endif

#if LIGHTING
	vec3 f0 = CAST3(0.04);
	f0 = mix(f0, color.rgb, metallic);

	// Using the actual view vector is ugly for ortho rendering
	vec3 normalizedViewVector = vec3(0, 0, 1); //normalize(v_ViewDir);

	vec3 light = ComputePBRLight(normal, v_Light0DirectionL3X.xyz, normalizedViewVector, color.rgb, g_LightsColorPremultiplied[0].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, v_Light1DirectionL3Y.xyz, normalizedViewVector, color.rgb, g_LightsColorPremultiplied[1].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, v_Light2DirectionL3Z.xyz, normalizedViewVector, color.rgb, g_LightsColorPremultiplied[2].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, vec3(v_Light0DirectionL3X.w, v_Light1DirectionL3Y.w, v_Light2DirectionL3Z.w),
		normalizedViewVector, color.rgb,
		vec3(g_LightsColorPremultiplied[0].w, g_LightsColorPremultiplied[1].w, g_LightsColorPremultiplied[2].w),
		f0, roughness, metallic);
	vec3 ambient = max(CAST3(0.001), g_LightAmbientColor) * color.rgb;

#if EMISSIVE_MAP
	light = max(light, g_EmissiveColor * color.rgb * (componentMaps.a * g_EmissiveBrightness));
#endif

	color.rgb = CombineLighting(light, ambient);
#endif

#if REFLECTION && NORMALMAP
	float reflectivity = g_Reflectivity;

#if REFLECTION_MAP
	reflectivity *= componentMaps.z;
#endif

	vec2 tangent = normalize(v_Tangent.xy);
	vec2 bitangent = normalize(v_Bitangent.xy);
	vec2 screenUV = (v_ScreenPos.xy / v_ScreenPos.z) * 0.5 + 0.5;

	float fresnelTerm = max(0.001, dot(normal, vec3(0, 0, 1)));
#if PLATFORM_ANDROID
	normal.xy = normalize(normal.xy) * vec2(0.25 / g_Screen.z, 0.25);
#else
	// Make consistent on X since the width is usually more variable (multi monitors) - bad for phones tho
	normal.xy = normalize(normal.xy) * vec2(0.15, 0.15 * g_Screen.z);
#endif
	screenUV += (tangent * normal.x + bitangent * normal.y) * fresnelTerm;

	vec3 reflectionColor = texSample2DLod(g_Texture3, screenUV, roughness * g_Texture3MipMapInfo).rgb;
	reflectionColor = reflectionColor * (1.0 - fresnelTerm) * reflectivity;
	reflectionColor = pow(max(CAST3(0.001), reflectionColor), CAST3(2.0 - metallic));

	color.rgb += saturate(reflectionColor);
#endif

#if HDR && EMISSIVE_MAP
	float emissiveOverbright = max(0.0, componentMaps.a * (g_EmissiveBrightness - 1.0));
	color.rgb += g_EmissiveColor * color.rgb * emissiveOverbright;
#endif

#ifdef SKINNING_ALPHA
	color.a *= v_BoneAlpha;
#endif

	gl_FragColor = color;

#if BLENDMODE
	vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5;
	vec4 screen = texSample2D(g_Texture4, screenCoord);

	gl_FragColor.rgb = ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a);
	gl_FragColor.a = screen.a;
#endif
}
