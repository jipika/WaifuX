
varying vec2 v_TexCoord[13];

uniform sampler2D g_Texture0;

void main() {
	vec3 albedo = texSample2D(g_Texture0, v_TexCoord[0]).rgb * 0.006299 +
					texSample2D(g_Texture0, v_TexCoord[1]).rgb * 0.017298 +
					texSample2D(g_Texture0, v_TexCoord[2]).rgb * 0.039533 +
					texSample2D(g_Texture0, v_TexCoord[3]).rgb * 0.075189 +
					texSample2D(g_Texture0, v_TexCoord[4]).rgb * 0.119007 +
					texSample2D(g_Texture0, v_TexCoord[5]).rgb * 0.156756 +
					texSample2D(g_Texture0, v_TexCoord[6]).rgb * 0.171834 +
					texSample2D(g_Texture0, v_TexCoord[7]).rgb * 0.156756 +
					texSample2D(g_Texture0, v_TexCoord[8]).rgb * 0.119007 +
					texSample2D(g_Texture0, v_TexCoord[9]).rgb * 0.075189 +
					texSample2D(g_Texture0, v_TexCoord[10]).rgb * 0.039533 +
					texSample2D(g_Texture0, v_TexCoord[11]).rgb * 0.017298 +
					texSample2D(g_Texture0, v_TexCoord[12]).rgb * 0.006299;
	
	gl_FragColor = vec4(albedo, 1.0);
}
