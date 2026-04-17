
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}

#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec4 v_PointerUV;
varying float v_PointerScale;

uniform float g_Multiply; // {"material":"multiply","label":"ui_editor_properties_multiply","default":1,"range":[0.0, 10.0]}

#if OPACITYMASK == 1
varying vec2 v_TexCoordOpacity;
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_blend_texture","default":"util/white"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_sprite","default":"particle/halo_6"}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"OPACITYMASK","paintdefaultcolor":"0 0 0 1"}


void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 mask = texSample2D(g_Texture1, v_TexCoord.zw);
	float blend = mask.a * g_Multiply;
	
#if OPACITYMASK
	blend *= texSample2D(g_Texture3, v_TexCoordOpacity).r;
#endif

	// Complete unproject per pixel
	vec2 unprojectedUVs = v_PointerUV.xy / v_PointerUV.z;
	
	vec2 texSource = v_TexCoord.xy;
	texSource.y = 1.0 - texSource.y;
	unprojectedUVs = (texSource - unprojectedUVs);
	unprojectedUVs = saturate(unprojectedUVs);
	
	// Scale sprite image around center
	unprojectedUVs -= 0.5;
	unprojectedUVs *= v_PointerScale * vec2(1.0, v_PointerUV.w);
	unprojectedUVs += 0.5;
	
	vec2 blendSample = texSample2D(g_Texture2, unprojectedUVs).ra;
	blend *= blendSample.x * blendSample.y;

	//blend = 0;
	//albedo.rgb = vec3(unprojectedUVs.xy, 0);

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, mask.rgb, blend);

	gl_FragColor = albedo;
}
