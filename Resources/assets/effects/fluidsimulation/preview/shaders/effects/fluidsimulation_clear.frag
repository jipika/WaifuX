
uniform sampler2D g_Texture0; // {"hidden":true}

varying vec3 v_TexCoord;

void main() {
	gl_FragColor = v_TexCoord.z * texSample2D(g_Texture0, v_TexCoord.xy);
}
