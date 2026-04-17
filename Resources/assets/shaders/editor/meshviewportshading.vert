
uniform mat4 g_ModelViewMatrix;
uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec4 a_Color;

varying vec4 v_ScreenPos;
varying vec4 v_ScreenNorm;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);

	vec3 normal = normalize(a_Color.rgb * 2.0 - 1.0);
	v_ScreenPos = gl_Position;
	v_ScreenNorm = mul(vec4(normal, 0.0), g_ModelViewProjectionMatrix);
}
