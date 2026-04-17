
varying vec4 v_TexCoord;
varying vec4 v_TexCoordIris;

uniform sampler2D g_Texture0; // {"material":"framebuffer", "label":"ui_editor_properties_framebuffer", "hidden":true}
uniform sampler2D g_Texture1; // {"material":"mask", "label":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec3 g_EyeColor; // {"material":"color", "label":"ui_editor_properties_background_color", "type": "color", "default":"1 1 1"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 iris = texSample2D(g_Texture0, v_TexCoordIris.xy);
	float mask = 1.0; //g_BlendAlpha;
	
#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
	float irisMask = texSample2D(g_Texture1, v_TexCoordIris.zw).r;
	iris.rgb = mix(g_EyeColor, iris.rgb, irisMask);
#endif

	albedo = mix(albedo, iris, mask);
	
	gl_FragColor = albedo;
}
