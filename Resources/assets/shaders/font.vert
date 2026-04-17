
uniform mat4 g_ModelMatrix;
uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec3 v_TexCoord;

void main() {
	gl_Position = mul(vec4(a_Position.xy, 0.0, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.z = a_Position.z;
}
