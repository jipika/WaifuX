
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":22}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":0}

#include "common.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec4 v_TexCoordNitro;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_albedo","default":"util/clouds_256"}
uniform sampler2D g_Texture2; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"MASK"}

uniform float g_NitroAlpha; // {"material":"ui_editor_properties_multiply","default":1.0,"range":[0.01, 10]}
uniform vec3 g_NitroColor0; // {"material":"ui_editor_properties_color_start","default":"0 1 1","type":"color"}
uniform vec3 g_NitroColor1; // {"material":"ui_editor_properties_color_end","default":"1 1 1","type":"color"}
uniform vec2 g_NitroRanges; // {"material":"ui_editor_properties_bounds","default":"0.3 0.25"}


void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float nitro0 = texSample2D(g_Texture1, v_TexCoordNitro.xy).r;
	float nitro1 = texSample2D(g_Texture1, v_TexCoordNitro.zw).r;
	float remap = texSample2D(g_Texture1, v_TexCoord.xy).r;
	
	vec2 noiseBase = g_NitroRanges;
	float coreNoise = smoothstep(nitro0, nitro1, 0.1 + remap * 0.8);
	float nitro = smoothstep(noiseBase.y, noiseBase.x, nitro0 * nitro1) * smoothstep(noiseBase.x, noiseBase.y, nitro0 * nitro1);
	nitro = coreNoise * nitro * 4;
	
	vec3 nitroColor = mix(g_NitroColor0, g_NitroColor1, nitro);
	
	float blend = nitro * g_NitroAlpha;
#if MASK == 1
	blend *= texSample2D(g_Texture2, v_TexCoord.zw).r;
#endif
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, nitroColor, blend);
	
#if WRITEALPHA == 1
	albedo.a = blend;
#endif
	
	gl_FragColor = albedo;
}
