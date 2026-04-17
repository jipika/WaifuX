
// [COMBO] {"material":"Blend mode","combo":"BLENDMODE","type":"imageblending","default":2}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Color mask","mode":"rgbmask","default":"util/white"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 mask = texSample2D(g_Texture1, v_TexCoord.zw);
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, mask.rgb, mask.a);
	
	gl_FragColor = albedo;
}
