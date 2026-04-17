

uniform sampler2D g_Texture0; // {"hidden":true}

varying vec4 v_TexCoordLeftTop;
varying vec4 v_TexCoordRightBottom;

void main() {
	vec2 vL = v_TexCoordLeftTop.xy;
	vec2 vR = v_TexCoordRightBottom.xy;
	vec2 vT = v_TexCoordLeftTop.zw;
	vec2 vB = v_TexCoordRightBottom.zw;
	
	float L = texSample2D(g_Texture0, vL).y;
	float R = texSample2D(g_Texture0, vR).y;
	float T = texSample2D(g_Texture0, vT).x;
	float B = texSample2D(g_Texture0, vB).x;
	float vorticity = R - L - T + B;
	//float vorticity = R - L - B + T;
	gl_FragColor = vec4(0.5 * vorticity, 0.0, 0.0, 1.0);
}
