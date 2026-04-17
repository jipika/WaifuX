
attribute vec4 a_PositionVec4;
attribute vec4 a_Color;

varying vec4 v_Color;

void main() {
	gl_Position = a_PositionVec4;
	v_Color = a_Color;
}
