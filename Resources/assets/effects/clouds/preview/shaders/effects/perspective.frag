
// [COMBO] {"material":"ui_editor_properties_repeat","combo":"REPEAT","type":"options","default":1}

varying vec3 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}

void main() {
	vec2 texCoord = v_TexCoord.xy / v_TexCoord.z;

#if REPEAT
	texCoord = frac(texCoord);
#endif
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
