
uniform vec4 g_Texture0Resolution;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoordLeftTop;
varying vec4 v_TexCoordRightBottom;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	vec2 texelSize = CAST2(1.0) / g_Texture0Resolution.xy;
	v_TexCoordLeftTop = a_TexCoord.xyxy;
	v_TexCoordRightBottom = a_TexCoord.xyxy;
	
	v_TexCoordLeftTop.x -= texelSize.x;
	v_TexCoordLeftTop.w += texelSize.y;
	v_TexCoordRightBottom.x += texelSize.x;
	v_TexCoordRightBottom.w -= texelSize.y;
}
