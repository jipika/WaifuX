
varying vec2 v_TexCoord[4];
varying vec2 v_TexCoordBase;

uniform sampler2D g_Texture0;

#if OPACITYMASK
uniform sampler2D g_Texture1;
#endif

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord[0]) +
					texSample2D(g_Texture0, v_TexCoord[1]) +
					texSample2D(g_Texture0, v_TexCoord[2]) +
					texSample2D(g_Texture0, v_TexCoord[3]);
	albedo *= 0.25;

#if OPACITYMASK
	albedo.a *= texSample2D(g_Texture1, v_TexCoordBase).r;
#endif

#if WRITEALPHA
	gl_FragColor = albedo;
#else
	gl_FragColor = vec4(albedo.rgb, 1.0);
#endif
}
