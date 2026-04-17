
#include "common_fragment.h"

varying vec4 v_TexCoord;
varying vec3 v_RefractTexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal","default":"","format":"normalmap","formatcombo":true}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

void main() {
#if MASK
	float mask = texSample2D(g_Texture2, v_TexCoord.zw).r;
#else
	float mask = 1;
#endif
	
	vec2 texCoord = v_TexCoord.xy;
	vec3 normal = DecompressNormal(texSample2D(g_Texture1, v_RefractTexCoord.xy));
	
	texCoord.xy += normal.xy * v_RefractTexCoord.z * mask;
	
	vec4 albedo = texSample2D(g_Texture0, texCoord.xy);
	
	//vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * CAST2(0.5) + 0.5;
	//vec4 bg = texSample2D(g_Texture3, screenCoord.xy);
	//albedo.rgb = mix(bg.rgb, albedo.rgb, albedo.a);
	//albedo.a = 1;
	
	gl_FragColor = albedo;
}
