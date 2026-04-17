
attribute vec3 a_Position;
attribute mediump vec2 a_TexCoord;

void main() {
	gl_Position = vec4(a_Position, 1.0);
}
