
varying vec2 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

void main() {
	vec2 texCoord = frac(v_TexCoord + v_Scroll);
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
