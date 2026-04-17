
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	albedo.rgb = pow(albedo.rgb, CAST3(2.2));
	gl_FragColor = albedo;
}
