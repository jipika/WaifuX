
uniform mat4 g_ViewProjectionMatrix;
uniform mat4 g_AltViewProjectionMatrix;

attribute vec3 a_Position;

void main() {
	gl_Position = mul(mul(vec4(a_Position, 1.0), g_AltViewProjectionMatrix), g_ViewProjectionMatrix);
}
