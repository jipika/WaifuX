
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord[4];

uniform vec4 g_Texture0Resolution;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	vec2 offsets = 1.0 / g_Texture0Resolution.xy;
	v_TexCoord[0] = a_TexCoord - offsets;
	v_TexCoord[1] = a_TexCoord + vec2(offsets.x, -offsets.y);
	v_TexCoord[2] = a_TexCoord + vec2(-offsets.x, offsets.y);
	v_TexCoord[3] = a_TexCoord + offsets;
}
