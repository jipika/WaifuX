
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":0}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}
// [COMBO] {"material":"ui_editor_properties_fog","combo":"FOG","default":1}

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

#include "common_pbr_2.h"
#include "common_blending.h"
#include "common_fog.h"

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
//uniform vec3 g_AmbientLowPass; // {"material":"ambientlowpass", "label":"ui_editor_properties_ambient", "type": "color", "default":"0 0 0","group":"ui_editor_properties_material"}
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
#elif FOG_COMPUTED && (FOG_HEIGHT || FOG_DIST)
varying vec4 v_ViewDir;
#endif

#if REFLECTION && NORMALMAP
uniform vec3 g_Screen;
uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
uniform float g_Reflectivity; // {"material":"reflectivity","label":"ui_editor_properties_reflectivity","default":1,"range":[0,1],"group":"ui_editor_properties_material","nobindings":true}
uniform float g_ReflectivityDistance; // {"material":"reflectivitydistance","label":"ui_editor_properties_reflectivity_distance","default":4,"range":[0.01,10],"group":"ui_editor_properties_material","nobindings":true,"hidden":true}
uniform float g_Texture3MipMapInfo;
#endif

#if REFLECTION && NORMALMAP || BLENDMODE || CLIPPINGUVS
varying vec3 v_ScreenPos;
#endif

#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif

#if MORPHING || SKINNING_ALPHA
varying float v_VertexAlpha;
#endif

#if CLIPPINGTARGET || CLIPPINGCOMPOSE
uniform sampler2D g_Texture8; // {"hidden":true}
#endif

#require LightingV1

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

	vec3 light = PerformLighting_V1(v_WorldPos, color.rgb, normal, normalizedViewVector, g_SpecularTint, f0, roughness, metallic);
	vec3 ambient = g_LightAmbientColor * color.rgb;

#if EMISSIVE_MAP
	light = max(light, g_EmissiveColor * color.rgb * (componentMaps.a * g_EmissiveBrightness));
#endif

	//color.rgb = CombineLighting(light, color.rgb * g_AmbientLowPass, ambient);
	color.rgb = CombineLighting(light, ambient);
#endif

#if REFLECTION && NORMALMAP || BLENDMODE || CLIPPINGUVS
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
	screenUV += normal.xy * pow(fresnelTerm, 4.0) * g_ReflectivityDistance;

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

#if FOG_COMPUTED && (FOG_HEIGHT || FOG_DIST)
	vec2 fogPixelState = CalculateFogPixelState(length(v_ViewDir.xyz), v_ViewDir.w);
	gl_FragColor.rgb = ApplyFog(gl_FragColor.rgb, fogPixelState);
#endif

#if CLIPPINGTARGET
	gl_FragColor.a *= texSample2D(g_Texture8, screenUV).r;
#endif

#if CLIPPINGCOMPOSE
	vec4 clippingComposeColor = texSample2D(g_Texture8, screenUV);
	gl_FragColor.rgb = mix(gl_FragColor.rgb, clippingComposeColor.rgb, clippingComposeColor.a);
#endif

#if ALPHATOCOVERAGE
	gl_FragColor.a = saturate((gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5);
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
