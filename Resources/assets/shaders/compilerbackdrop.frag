
uniform float g_Alpha;

varying vec2 v_TexCoord;

void main() {
	float fade = smoothstep(0.2, 0.3, v_TexCoord.y) * smoothstep(0.8, 0.7, v_TexCoord.y);
	gl_FragColor = vec4(0, 0, 0, fade * g_Alpha);
}
