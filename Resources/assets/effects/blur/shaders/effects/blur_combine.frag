
// [COMBO] {"material":"ui_editor_properties_composite","combo":"COMPOSITE","type":"options","default":0,"options":{"ui_editor_properties_normal":0,"ui_editor_properties_blend":1,"ui_editor_properties_under":2,"ui_editor_properties_cutout":3}}
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}
// [COMBO] {"material":"ui_editor_properties_monochrome","combo":"COMPOSITEMONO","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_blur_alpha","combo":"BLURALPHA","type":"options","default":1}

#include "common_composite.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"hidden":true}

uniform vec4 g_Texture0Resolution;

void main() {

	vec2 blurredCoords = v_TexCoord.xy;
	
#ifdef HLSL_SM30
	blurredCoords += 0.75 / g_Texture0Resolution.zw;
#endif

	vec4 blurred = texSample2D(g_Texture0, ApplyCompositeOffset(blurredCoords, g_Texture0Resolution.xy));
	vec4 albedoOld = texSample2D(g_Texture2, v_TexCoord.xy);
	
#if MASK
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1.0;
#endif
	
	float div = mix(blurred.a, 1, step(blurred.a, 0));
	blurred = ApplyComposite(albedoOld, vec4(blurred.rgb / div, blurred.a));
	blurred = mix(albedoOld, blurred, mask);

#if BLURALPHA == 0
	blurred.a = albedoOld.a;
#endif
	
	gl_FragColor = blurred;
}
