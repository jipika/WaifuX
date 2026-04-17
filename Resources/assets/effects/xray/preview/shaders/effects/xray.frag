
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}

#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec3 v_PointerUV;

uniform float g_Multiply; // {"material":"ui_editor_properties_multiply","default":1,"range":[0.0, 10.0]}
uniform float g_PointerScale; // {"material":"ui_editor_particle_element_exponent","default":5,"range":[0.01, 20.0]}

#if OPACITYMASK == 1
varying vec2 v_TexCoordOpacity;
#endif

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
uniform sampler2D g_Texture2; // {"material":"ui_editor_properties_sprite","default":"particle/halo"}
uniform sampler2D g_Texture3; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"OPACITYMASK"}


void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 mask = texSample2D(g_Texture1, v_TexCoord.zw);
	float blend = mask.a * g_Multiply;
	
#if OPACITYMASK == 1
	blend *= texSample2D(g_Texture3, v_TexCoordOpacity).r;
#endif

	// Complete unproject per pixel
	vec2 unprojectedUVs = v_PointerUV.xy / v_PointerUV.z;
	
	vec2 texS = v_TexCoord.xy;
	texS.y = 1.0 - texS.y;
	unprojectedUVs = (texS - unprojectedUVs);
	unprojectedUVs = saturate(unprojectedUVs);
	
	// Scale sprite image around center
	unprojectedUVs -= 0.5;
	unprojectedUVs *= g_PointerScale;
	unprojectedUVs += 0.5;
	
	vec2 blendSample = texSample2D(g_Texture2, unprojectedUVs).ra;
	blend *= blendSample.x * blendSample.y;

	//blend = 0;
	//albedo.rgb = vec3(unprojectedUVs.xy, 0);

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, mask.rgb, blend);

	gl_FragColor = albedo;
}
