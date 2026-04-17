
// [COMBO] {"material":"ui_editor_properties_blur_alpha","combo":"BLURALPHA","type":"options","default":1}

#include "common_blur.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float u_Scale; // {"default":1,"label":"ui_editor_properties_scale","material":"scale","range":[0.01,2.0]}
uniform vec2 u_Center; // {"label":"ui_editor_properties_center","material":"center","position":true,"default":"0.5 0.5"}

#if MASK
varying vec2 v_TexCoordMask;
#endif

void main() {
#if KERNEL == 0
	vec4 albedo = blurRadial13a(v_TexCoord.xy, u_Center, u_Scale);
#endif
#if KERNEL == 1
	vec4 albedo = blurRadial7a(v_TexCoord.xy, u_Center, u_Scale);
#endif
#if KERNEL == 2
	vec4 albedo = blurRadial3a(v_TexCoord.xy, u_Center, u_Scale);
#endif

#if MASK || BLURALPHA == 0
	vec4 prev = texSample2D(g_Texture0, v_TexCoord.xy);
#endif

#if MASK
	albedo = mix(prev, albedo, texSample2D(g_Texture1, v_TexCoordMask.xy).r);
#endif

#if BLURALPHA == 0
	albedo.a = prev.a;
#endif

	gl_FragColor = albedo;
}
