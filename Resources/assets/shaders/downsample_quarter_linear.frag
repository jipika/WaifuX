
varying vec2 v_TexCoord[4];

uniform sampler2D g_Texture0;

void main() {
	vec3 albedo = texSample2D(g_Texture0, v_TexCoord[0]).rgb +
					texSample2D(g_Texture0, v_TexCoord[1]).rgb +
					texSample2D(g_Texture0, v_TexCoord[2]).rgb +
					texSample2D(g_Texture0, v_TexCoord[3]).rgb;
	albedo *= 0.25;
	
	gl_FragColor = vec4(pow(albedo, 1/2.2), 1.0);
}
