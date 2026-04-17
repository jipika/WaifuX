
// [COMBO] {"material":"ui_editor_properties_blur_alpha","combo":"BLURALPHA","type":"options","default":1}

#include "common_blur.h"

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1","require":{"ENABLEMASK":1}}

#if MASK
varying vec2 v_TexCoordMask;
#endif

void main() {
#if KERNEL == 0
	vec4 albedo = blur13a(v_TexCoord.xy, v_TexCoord.zw);
#endif
#if KERNEL == 1
	vec4 albedo = blur7a(v_TexCoord.xy, v_TexCoord.zw);
#endif
#if KERNEL == 2
	vec4 albedo = blur3a(v_TexCoord.xy, v_TexCoord.zw);
#endif

#if MASK || BLURALPHA == 0
	vec4 prev = texSample2D(g_Texture1, v_TexCoord.xy);
#endif

#if MASK
	albedo = mix(prev, albedo, texSample2D(g_Texture2, v_TexCoordMask.xy).r);
#endif

#if BLURALPHA == 0
	albedo.a = prev.a;
#endif

	gl_FragColor = albedo;
}
