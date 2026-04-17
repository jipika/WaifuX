
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":12}
// [COMBO] {"material":"ui_editor_properties_greyscale","combo":"GREYSCALE","type":"options","default":1}

#include "common.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec4 v_TexCoordNoise;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_noise","default":"util/noise"}
uniform sampler2D g_Texture2; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"MASK"}

uniform float g_NoiseAlpha; // {"material":"ui_editor_properties_strength","default":2,"range":[0.0, 5.0]}
uniform float g_NoisePower; // {"material":"ui_editor_properties_power","default":0.5,"range":[0.0, 5.0]}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	vec3 noise = texSample2D(g_Texture1, v_TexCoordNoise.xy).rgb;
	vec3 noise2 = texSample2D(g_Texture1, v_TexCoordNoise.zw).gbr;
	
#if GREYSCALE == 1
	noise = CAST3(greyscale(noise));
	noise2 = CAST3(greyscale(noise2));
#endif
	
	noise = saturate(noise * noise2);
	noise = pow(noise, g_NoisePower);
	
	float blend = g_NoiseAlpha;
#if MASK == 1
	blend *= texSample2D(g_Texture2, v_TexCoord.zw).r;
#endif

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, noise, blend);
	
	gl_FragColor = albedo;
}
