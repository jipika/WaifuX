
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":30}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_BlendAlpha; // {"material":"alpha", "label":"ui_editor_properties_alpha","default":1,"range":[0,1]}
uniform vec3 g_TintColor; // {"material":"color", "label":"ui_editor_properties_color", "type": "color", "default":"1 0 0"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float mask = g_BlendAlpha;
	
#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, g_TintColor, mask);
	
#if BLENDMODE == 0
	albedo.a = 1.0;
#endif
	
	gl_FragColor = albedo;
}
