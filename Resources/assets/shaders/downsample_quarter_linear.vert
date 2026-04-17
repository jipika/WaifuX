
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform vec2 g_TexelSize;

varying vec2 v_TexCoord[4];

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord[0] = a_TexCoord - g_TexelSize * 2;
	v_TexCoord[1] = a_TexCoord + g_TexelSize * 2;
	v_TexCoord[2] = a_TexCoord + vec2(-g_TexelSize.x, g_TexelSize.y) * 2;
	v_TexCoord[3] = a_TexCoord + vec2(g_TexelSize.x, -g_TexelSize.y) * 2;
}
