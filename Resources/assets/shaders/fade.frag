
varying mediump vec2 v_TexCoord;

uniform mediump float g_Alpha;

uniform lowp vec3 color; // {"material":"tint","default":"0.315, 0.135, 0.1125"}

void main() {
	gl_FragColor = vec4(color * 0.7, g_Alpha);
}
