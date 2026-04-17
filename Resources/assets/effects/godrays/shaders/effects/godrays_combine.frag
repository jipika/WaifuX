
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":9}
// [COMBO] {"material":"ui_editor_properties_copy_background","combo":"COPYBG","type":"options"}

#include "common_blending.h"

varying vec4 v_TexCoord;

#if COPYBG
varying vec3 v_ScreenCoord;

uniform sampler2D g_Texture2; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}

void main() {

	vec4 rays = texSample2D(g_Texture0, v_TexCoord.zw);
	vec4 albedo = texSample2D(g_Texture1, v_TexCoord.xy);
	
#if COPYBG
	vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5;
	vec4 bg = texSample2D(g_Texture2, screenCoord.xy);
	albedo.rgb = mix(bg.rgb, albedo.rgb, albedo.a);
#endif

#if BLENDMODE == 0
	albedo = rays;
#else
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, rays.rgb, rays.a);
	albedo.a = saturate(albedo.a + rays.a);
#endif
	
	gl_FragColor = albedo;
}
