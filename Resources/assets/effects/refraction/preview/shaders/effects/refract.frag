
#include "common_fragment.h"

varying vec4 v_TexCoord;
varying vec3 v_RefractTexCoord;

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"mask","label":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"material":"normalmap","label":"ui_editor_properties_normal","default":"","format":"normalmap"}

void main() {
#if MASK == 1
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1;
#endif
	
	vec2 texCoord = v_TexCoord.xy;
	vec3 normal = DecompressNormal(texSample2D(g_Texture2, v_RefractTexCoord.xy));
	
	texCoord.xy += normal.xy * v_RefractTexCoord.z * mask;
	
	vec4 albedo = texSample2D(g_Texture0, texCoord.xy);
	
	//vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * CAST2(0.5) + 0.5;
	//vec4 bg = texSample2D(g_Texture3, screenCoord.xy);
	//albedo.rgb = mix(bg.rgb, albedo.rgb, albedo.a);
	//albedo.a = 1;
	
	gl_FragColor = albedo;
}
