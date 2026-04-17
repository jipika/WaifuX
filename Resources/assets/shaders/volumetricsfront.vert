
uniform mat4 g_ViewProjectionMatrix;
uniform mat4 g_AltViewProjectionMatrix;

attribute vec3 a_Position;

varying vec4 v_ScreenPos;

void main() {
#if POINTLIGHT
	gl_Position = mul(mul(vec4(a_Position, 1.0), g_AltViewProjectionMatrix), g_ViewProjectionMatrix);
#else
	gl_Position = mul(mul(vec4(a_Position * vec3(0.99, 0.99, 1.0), 1.0), g_AltViewProjectionMatrix), g_ViewProjectionMatrix);
#endif

#if FULLSCREEN
#if REVERSEDEPTH
	gl_Position = vec4(a_Position.xy, 1.0, 1.0);
#else
	gl_Position = vec4(a_Position.xy, 0.0, 1.0);
#endif
#endif

	v_ScreenPos = gl_Position;
}
