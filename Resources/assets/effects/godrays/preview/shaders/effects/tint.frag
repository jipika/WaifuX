
// [COMBO] {"material":"Blend mode","combo":"BLENDMODE","type":"imageblending","default":2}

#include "common_blending.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_BlendAlpha; // {"material":"Alpha","default":1,"range":[0,1]}
uniform vec3 g_TintColor; // {"material":"Color", "type": "color", "default":"1 1 1"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, g_TintColor, g_BlendAlpha);
	
	gl_FragColor = albedo;
}
