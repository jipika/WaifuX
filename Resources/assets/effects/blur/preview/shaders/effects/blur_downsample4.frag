
varying vec4 v_TexCoord01;
varying vec4 v_TexCoord23;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

void main() {
	gl_FragColor = (texSample2D(g_Texture0, v_TexCoord01.xy) +
					texSample2D(g_Texture0, v_TexCoord01.zw) +
					texSample2D(g_Texture0, v_TexCoord23.xy) +
					texSample2D(g_Texture0, v_TexCoord23.zw)) * 0.25;
}
