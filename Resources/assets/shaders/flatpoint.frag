
uniform mediump float g_Alpha;
uniform mediump vec3 g_Color;

varying vec4 v_Color;

void main() {
	gl_FragColor = vec4(g_Color, g_Alpha);
	gl_FragColor *= v_Color;
}