
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":0}
// [COMBO] {"material":"ui_editor_properties_double_sided_lighting","combo":"DOUBLESIDEDLIGHTING","default":0,"require":{"LIGHTING":1}}
// [COMBO] {"material":"ui_editor_properties_fog","combo":"FOG","default":1}
// [COMBO] {"material":"ui_editor_properties_refract","combo":"REFRACT","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_cutout","combo":"CUTOUT","default":0}

#include "common_fragment.h"
#include "common_fog.h"

uniform sampler2D g_Texture0; // {"label":"ui_editor_properties_albedo","default":"util/white"}
uniform float g_Overbright; // {"material":"ui_editor_properties_overbright","default":1.0,"range":[0,5]}
uniform float g_CutoutStart; // {"material":"ui_editor_properties_cutout_start","default":0.1,"range":[0,1],"order":1}
uniform float g_CutoutEnd; // {"material":"ui_editor_properties_cutout_end","default":0.2,"range":[0,1],"order":2}
uniform float g_CutoutOpacity; // {"material":"ui_editor_properties_cutout_opacity","default":1,"range":[0,1],"order":3}

#if REFRACT || LIGHTING
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal","format":"normalmap","formatcombo":true,"combo":"NORMALMAP","require":{"REFRACT":1,"LIGHTING":1},"requireany":true}
#endif

#if REFRACT
uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
#endif

#if SPRITESHEET
varying vec4 v_TexCoord;
varying float v_TexCoordBlend;
#else
varying vec2 v_TexCoord;
#endif

varying vec4 v_Color;

#if REFRACT
varying vec3 v_ScreenCoord;
varying vec4 v_ScreenTangents;
#endif

#if FOG_DIST || FOG_HEIGHT || LIGHTING
varying vec4 v_ViewDir;
#endif

#if LIGHTS_SHADOW_MAPPING
#define SHADOW_ATLAS_SAMPLER g_Texture4
#define SHADOW_ATLAS_TEXEL g_Texture4Texel
uniform sampler2DComparison g_Texture4; // {"hidden":true,"default":"_rt_shadowAtlas"}
uniform vec4 g_Texture4Texel;
#endif

#if LIGHTS_COOKIE
#define COOKIE_SAMPLER g_Texture5
uniform sampler2D g_Texture5; // {"hidden":true,"default":"_alias_lightCookie"}
#endif

#if LIGHTING
varying vec3 v_WorldPos;
varying vec3 v_WorldRight;
uniform vec3 g_LightAmbientColor;
uniform vec3 g_LightSkylightColor;
uniform vec3 g_ViewRight;
uniform vec3 g_ViewUp;

#ifndef NORMALMAP
#define DOUBLESIDEDLIGHTING 1
#endif
#include "common_pbr_2.h"
#require LightingV1
#endif

void main() {
#if SPRITESHEET
#if SPRITESHEETBLEND
	// This is wrong because it can sample colors that are invisible on one frame but changing this can negatively impact additive particles
	vec4 color = v_Color * mix(ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.xy)),
								ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.zw)),
								v_TexCoordBlend);
#else
	vec4 color = v_Color * ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.xy));
#endif
#else
	vec4 color = v_Color * ConvertTexture0Format(texSample2D(g_Texture0, v_TexCoord.xy));
#endif

#if (REFRACT || LIGHTING) && NORMALMAP
	vec4 normal = DecompressNormalWithMask(texSample2D(g_Texture1, v_TexCoord.xy));
#endif

#if LIGHTING
	vec3 normalizedViewDir = normalize(v_ViewDir.xyz);
#if NORMALMAP
	vec3 worldNormal = normalizedViewDir * normal.z + v_WorldRight * normal.x + cross(v_WorldRight, normalizedViewDir) * normal.y;
#else
	vec3 worldNormal = normalizedViewDir;
#endif
	vec3 f0 = CAST3(0.04);
	vec3 light = PerformLighting_V1(v_WorldPos, color.rgb, worldNormal, normalizedViewDir, CAST3(1.0), f0, 0.0, 0.0);
	color.rgb = g_LightAmbientColor * color.rgb;
	color.rgb = CombineLighting(light, color.rgb);
#endif

	//normal = vec4((v_TexCoord.xy - 0.5) * 2, 0, 1);
#if REFRACT && NORMALMAP
	vec2 screenRefractionOffset = v_ScreenTangents.xy * normal.x + v_ScreenTangents.zw * normal.y;
#ifndef HLSL
	screenRefractionOffset.y = -screenRefractionOffset.y;
#endif
	vec2 refractTexCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5 + screenRefractionOffset * normal.a * v_Color.a;

	color.rgb *= texSample2D(g_Texture3, refractTexCoord).rgb;
#endif

	color.rgb *= g_Overbright;

#if CUTOUT
	color.a = smoothstep(g_CutoutStart, g_CutoutEnd, color.a) * g_CutoutOpacity;
#endif

#if FOG_HEIGHT || FOG_DIST
	vec2 fogPixelState = CalculateFogPixelState(length(v_ViewDir.xyz), v_ViewDir.w);
	color.rgb = ApplyFog(color.rgb, fogPixelState);
	color.a = ApplyFogAlpha(color.a, fogPixelState);
#endif

	gl_FragColor = color;

#if ALPHATOCOVERAGE
	gl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}