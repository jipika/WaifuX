
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform vec4 g_Texture0Texel;

varying vec2 v_TexCoord[4];
varying vec2 v_TexCoordBase;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord[0] = a_TexCoord - g_Texture0Texel.xy * 2;
	v_TexCoord[1] = a_TexCoord + g_Texture0Texel.xy * 2;
	v_TexCoord[2] = a_TexCoord + vec2(-g_Texture0Texel.x, g_Texture0Texel.y) * 2;
	v_TexCoord[3] = a_TexCoord + vec2(g_Texture0Texel.x, -g_Texture0Texel.y) * 2;
	v_TexCoordBase = a_TexCoord;
}
