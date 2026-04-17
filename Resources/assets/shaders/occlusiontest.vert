
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;
uniform mat4 g_ModelViewProjectionMatrix;

void main() {
	vec3 position = a_Position +
		(g_ViewRight * (a_TexCoord.x-0.5) +
		g_ViewUp * (a_TexCoord.y-0.5)) * 0.5;

	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
#if REVERSEDEPTH
	gl_Position.z = 0.0000001;
#else
	gl_Position.z = 0.999 * gl_Position.w;
#endif
}
