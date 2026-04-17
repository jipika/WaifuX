
#if KERNEL == 0
varying vec2 v_TexCoord[13];
#endif
#if KERNEL == 1
varying vec2 v_TexCoord[7];
#endif
#if KERNEL == 2
varying vec2 v_TexCoord[3];
#endif

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
#if KERNEL == 0
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord[0]) * 0.006299 +
					texSample2D(g_Texture0, v_TexCoord[1]) * 0.017298 +
					texSample2D(g_Texture0, v_TexCoord[2]) * 0.039533 +
					texSample2D(g_Texture0, v_TexCoord[3]) * 0.075189 +
					texSample2D(g_Texture0, v_TexCoord[4]) * 0.119007 +
					texSample2D(g_Texture0, v_TexCoord[5]) * 0.156756 +
					texSample2D(g_Texture0, v_TexCoord[6]) * 0.171834 +
					texSample2D(g_Texture0, v_TexCoord[7]) * 0.156756 +
					texSample2D(g_Texture0, v_TexCoord[8]) * 0.119007 +
					texSample2D(g_Texture0, v_TexCoord[9]) * 0.075189 +
					texSample2D(g_Texture0, v_TexCoord[10]) * 0.039533 +
					texSample2D(g_Texture0, v_TexCoord[11]) * 0.017298 +
					texSample2D(g_Texture0, v_TexCoord[12]) * 0.006299;
#endif
#if KERNEL == 1
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord[0]) * 0.071303 +
					texSample2D(g_Texture0, v_TexCoord[1]) * 0.131514 +
					texSample2D(g_Texture0, v_TexCoord[2]) * 0.189879 +
					texSample2D(g_Texture0, v_TexCoord[3]) * 0.214607 +
					texSample2D(g_Texture0, v_TexCoord[4]) * 0.189879 +
					texSample2D(g_Texture0, v_TexCoord[5]) * 0.131514 +
					texSample2D(g_Texture0, v_TexCoord[6]) * 0.071303;
#endif
#if KERNEL == 2
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord[0]) * 0.25 +
					texSample2D(g_Texture0, v_TexCoord[1]) * 0.5 +
					texSample2D(g_Texture0, v_TexCoord[2]) * 0.25;
#endif

	gl_FragColor = albedo;
}
