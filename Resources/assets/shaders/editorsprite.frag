
uniform sampler2D g_Texture0;
uniform vec3 g_Color;
uniform float g_Alpha;

varying vec2 v_TexCoord;

void main() {
	vec4 color = texSample2D(g_Texture0, v_TexCoord);
	color.rgb *= g_Color;
	color.a *= g_Alpha;
	gl_FragColor = color;
}