
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec2 v_NoiseCoord;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord.xy = a_TexCoord.xy;

	v_NoiseCoord = vec2(a_TexCoord.x, a_TexCoord.y) * 5;
}
