
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	gl_FragColor = albedo;
}
