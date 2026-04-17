
uniform mat4 g_ModelMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelMatrix);
	v_TexCoord = a_TexCoord;
}
