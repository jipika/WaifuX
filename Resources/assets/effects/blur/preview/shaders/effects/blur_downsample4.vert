
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord01;
varying vec4 v_TexCoord23;

uniform vec4 g_Texture0Resolution;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	vec2 offsets = 1.0 / g_Texture0Resolution.zw;
	v_TexCoord01.xy = a_TexCoord - offsets;
	v_TexCoord01.zw = a_TexCoord + vec2(offsets.x, -offsets.y);
	v_TexCoord23.xy = a_TexCoord + vec2(-offsets.x, offsets.y);
	v_TexCoord23.zw = a_TexCoord + offsets;
}
