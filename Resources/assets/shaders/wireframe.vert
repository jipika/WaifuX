
attribute vec3 a_Position;
attribute vec4 a_Color;

uniform mat4 g_ModelViewProjectionMatrix;

varying mediump vec4 v_Color;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_Color = a_Color;
}
