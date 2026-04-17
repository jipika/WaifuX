
uniform mat4 g_ModelMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec4 v_ViewRect;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	//v_TexCoord = a_TexCoord;
	
	v_TexCoord.x = mix(g_ModelMatrix[1][0], g_ModelMatrix[1][2], a_TexCoord.x);
	v_TexCoord.y = mix(g_ModelMatrix[1][3], g_ModelMatrix[1][1], a_TexCoord.y);
	v_ViewRect = g_ModelMatrix[0];
}
