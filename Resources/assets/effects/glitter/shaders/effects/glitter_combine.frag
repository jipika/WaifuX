
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":32}

#include "common_blending.h"

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"label":"glitter","hidden":true}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_Time;
uniform vec4 g_Texture0Resolution;

uniform float g_GlitterScale; // {"material":"scale","label":"ui_editor_properties_granularity","default":1,"range":[0.1, 5]}
uniform float g_GlitterOpacity; // {"material":"alpha","label":"ui_editor_properties_brightness","default":1,"range":[0, 5]}
uniform vec3 g_GlitterColor; // {"material":"color","label":"ui_editor_properties_color","default":"1 1 1","type":"color"}

varying vec4 v_TexCoord;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float mask = 1.0;

#if MASK
	mask *= texSample2D(g_Texture2, v_TexCoord.zw).r;
#endif

	vec2 glitterCoords = v_TexCoord.xy;
	glitterCoords.x *= g_Texture0Resolution.x/g_Texture0Resolution.y;
	float glitter = texSample2D(g_Texture1, glitterCoords * g_GlitterScale).r;

	vec3 glitterColor = g_GlitterColor * glitter;

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, glitterColor, g_GlitterOpacity * mask);
	
	gl_FragColor = albedo;
}
