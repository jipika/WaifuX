
#include "common_fragment.h"

uniform vec4 g_LightsColorRadius[4];

uniform float g_Metallic; // {"material":"Metal","default":0,"range":[0,1]}
uniform float g_Roughness; // {"material":"Rough","default":0,"range":[0,1]}
uniform float g_Light; // {"material":"Light","default":0,"range":[0,1]}

#if DIFFUSETINT
uniform vec3 g_TintColor; // {"material":"Color", "type": "color", "default":"1 1 1"}
uniform float g_TintAlpha; // {"material":"Alpha","default":0,"range":[0,1]}
#endif

uniform sampler2D g_Texture0;

#if NORMALMAP

uniform sampler2D g_Texture1;
#define g_NormalMapSampler g_Texture1

#if LIGHTMAP
uniform sampler2D g_Texture2;
#define g_LightmapMapSampler g_Texture2
#endif

#else

#if LIGHTMAP
uniform sampler2D g_Texture1;
#define g_LightmapMapSampler g_Texture1
#endif

varying vec3 v_Normal;

#endif

#if REFLECTION
uniform sampler2D g_Texture3;
#define g_ReflectionSampler g_Texture3

varying vec3 v_ScreenPos;
uniform vec2 g_TexelSizeHalf;
#endif

#if LIGHTMAP
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif

varying vec3 v_ViewDir;
varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;
varying vec3 v_LightAmbientColor;

void main() {
	// Vars
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec3 specularResult = vec3(0, 0, 0);

#if DIFFUSETINT
	albedo.rgb *= g_TintColor;
	albedo.a *= g_TintAlpha;
#endif
	
#if DETAILINALPHA
	albedo.rgb *= texSample2D(g_Texture0, v_TexCoord.xy * 3).a * 2.0;
#endif
	
	vec3 viewDir = normalize(v_ViewDir);
	float specularPower = ComputeMaterialSpecularPower(g_Roughness, g_Metallic);
	float specularStrength = ComputeMaterialSpecularStrength(g_Roughness, g_Metallic);
	
#if NORMALMAP
	vec3 normal = DecompressNormal(texSample2D(g_NormalMapSampler, v_TexCoord.xy));
#else
	vec3 normal = normalize(v_Normal);
#endif
	
	// Compute fragment
	vec3 light = ComputeLightSpecular(normal, v_Light0DirectionL3X.xyz, g_LightsColorRadius[0].rgb, g_LightsColorRadius[0].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, specularResult);
	
#if LIGHTMAP
	vec3 lightmap = texSample2D(g_LightmapMapSampler, v_TexCoord.zw).rgb;
	light *= lightmap;
	specularResult *= lightmap;
#endif

	light += ComputeLightSpecular(normal, v_Light1DirectionL3Y.xyz, g_LightsColorRadius[1].rgb, g_LightsColorRadius[1].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, specularResult);
	
	light += ComputeLightSpecular(normal, v_Light2DirectionL3Z.xyz, g_LightsColorRadius[2].rgb, g_LightsColorRadius[2].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, specularResult);
	
	light += ComputeLightSpecular(normal, vec3(v_Light0DirectionL3X.w, v_Light1DirectionL3Y.w, v_Light2DirectionL3Z.w), g_LightsColorRadius[3].rgb, g_LightsColorRadius[3].w, viewDir, specularPower, specularStrength, g_Light, g_Metallic, specularResult);

	light += v_LightAmbientColor;
	albedo.rgb = albedo.rgb * light + specularResult;

#if REFLECTION
	vec2 screenUV = (v_ScreenPos.xy / v_ScreenPos.z) * 0.5 + 0.5;
#ifdef HLSL_SM30
	screenUV += g_TexelSizeHalf;
#endif
	albedo.rgb += texSample2D(g_ReflectionSampler, screenUV + normal.xy * 0.01).rgb * 0.35;
#endif

	gl_FragColor = albedo;
}
