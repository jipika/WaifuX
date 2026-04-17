
// [COMBO] {"material":"ui_editor_properties_repeat","combo":"REPEAT","type":"options","default":0}

varying vec3 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	vec2 texCoord = v_TexCoord.xy / v_TexCoord.z;

	float mask = step(0.0, v_TexCoord.z);
	
#if REPEAT
	texCoord = frac(texCoord);
#else
	mask *= step(abs(texCoord.x - 0.5), 0.5);
	mask *= step(abs(texCoord.y - 0.5), 0.5);
#endif

	gl_FragColor = texSample2D(g_Texture0, texCoord);
	gl_FragColor.a *= mask;
}
