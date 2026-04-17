
// [COMBO] {"material":"ui_editor_properties_background","combo":"BACKGROUND","type":"options","default":0}

varying vec4 v_TexCoord;
varying vec2 v_TexCoordIris;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec3 g_EyeColor; // {"material":"color", "label":"ui_editor_properties_background_color", "type": "color", "default":"1 1 1"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float mask = 1.0;
	
#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
	vec4 iris = texSample2D(g_Texture0, v_TexCoord.xy + v_TexCoordIris.xy * mask);
	float irisMask = texSample2D(g_Texture1, v_TexCoord.zw + v_TexCoordIris.xy * mask).r;
#if BACKGROUND
	iris.rgb = mix(g_EyeColor, iris.rgb, irisMask);
#endif
#else
	vec4 iris = texSample2D(g_Texture0, v_TexCoord.xy + v_TexCoordIris.xy);
#endif

	//albedo = mix(albedo, iris, mask);
	albedo = iris;
	
	gl_FragColor = albedo;
}
