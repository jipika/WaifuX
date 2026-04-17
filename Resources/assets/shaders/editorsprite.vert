
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

//uniform mat4 g_ModelMatrix;
//uniform mat4 g_ViewProjectionMatrix;
uniform mat4 g_ModelViewProjectionMatrix;

uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;

varying vec2 v_TexCoord;

void main() {
	vec3 position = a_Position +
		(g_ViewRight * -(a_TexCoord.x-0.5) +
		g_ViewUp * (a_TexCoord.y-0.5)) * -0.5;

	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord;
}
