
// [COMBO] {"material":"ui_editor_properties_repeat","combo":"CLAMP","type":"options","default":1}

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec2 texCoord = v_TexCoord;
#if CLAMP
	texCoord = frac(texCoord);
#endif
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
