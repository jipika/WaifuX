
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_UserAlpha; // {"material":"alpha","label":"ui_editor_properties_alpha","default":1.0,"range":[0.01, 1]}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
#if MASK
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1.0;
#endif
	albedo.a *= mask * g_UserAlpha;
	
	gl_FragColor = albedo;
}
