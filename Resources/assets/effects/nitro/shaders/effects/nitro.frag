
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":22}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":0}

#include "common.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec4 v_TexCoordNitro;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_albedo","default":"util/clouds_256"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_NitroAlpha; // {"material":"multiply","label":"ui_editor_properties_multiply","default":1.0,"range":[0.01, 10]}
uniform vec3 g_NitroColor0; // {"material":"colorstart","label":"ui_editor_properties_color_start","default":"0 0.5 1","type":"color"}
uniform vec3 g_NitroColor1; // {"material":"colorend","label":"ui_editor_properties_color_end","default":"1 1 1","type":"color"}
uniform vec2 g_NitroRanges; // {"material":"bounds","label":"ui_editor_properties_bounds","default":"0.3 0.25"}
uniform float g_NitroLOD; // {"material":"smoothness","label":"ui_editor_properties_smoothness","default":1,"range":[0.0, 5]}


void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float nitro0 = texSample2DLod(g_Texture1, v_TexCoordNitro.xy, g_NitroLOD).r;
	float nitro1 = texSample2DLod(g_Texture1, v_TexCoordNitro.zw, g_NitroLOD).r;
	float remap = texSample2D(g_Texture1, v_TexCoord.xy).r;
	
	vec2 noiseBase = g_NitroRanges;
	float coreNoise = smoothstep(nitro0, nitro1, 0.1 + remap * 0.8);
	float nitro = smoothstep(noiseBase.y, noiseBase.x, nitro0 * nitro1) * smoothstep(noiseBase.x, noiseBase.y, nitro0 * nitro1);
	nitro = coreNoise * nitro * 4;
	
	vec3 nitroColor = mix(g_NitroColor0, g_NitroColor1, nitro);
	
	float blend = nitro * g_NitroAlpha;
#if MASK
	blend *= texSample2D(g_Texture2, v_TexCoord.zw).r;
#endif
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, nitroColor, blend);
	
#if WRITEALPHA
	albedo.a = blend;
#endif
	
	gl_FragColor = vec4(max(0, albedo.rgb), albedo.a);
}
