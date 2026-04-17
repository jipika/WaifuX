
attribute vec3 a_Position;

uniform mat4 g_ModelViewProjectionMatrix;

varying vec3 g_ScreenPosition;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	
	g_ScreenPosition = gl_Position.xyw;
}
