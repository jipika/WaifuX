
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":9}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Prev","hidden":true}

void main() {

	vec4 rays = texSample2D(g_Texture0, v_TexCoord.zw);
	vec4 albedo = texSample2D(g_Texture1, v_TexCoord.xy);
	
#if BLENDMODE == 0
	albedo = rays;
#else
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, rays.rgb, rays.a);
	albedo.a += rays.a;
#endif
	
	gl_FragColor = albedo;
}
