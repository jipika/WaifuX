
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;


void main() {

	vec3 albedo = texSample2D(g_Texture0, v_TexCoord).rgb;

	vec3 bloom = texSample2D(g_Texture1, v_TexCoord).rgb;
	albedo += bloom;
	
	gl_FragColor = vec4(albedo, 1.0);
}
