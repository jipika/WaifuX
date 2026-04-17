#if ALPHATOCOVERAGE
uniform sampler2D g_Texture0; // {"material":"albedo"}

varying vec2 v_TexCoord;
#endif

void main() {
#if ALPHATOCOVERAGE
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	albedo.a = (albedo.a - 0.5) / max(fwidth(albedo.a), 0.0001) + 0.5;
	gl_FragColor = albedo;
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
