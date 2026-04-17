
uniform sampler2D g_Texture0; // {"hidden":true}

varying vec2 v_TexCoord;
varying vec4 v_TexCoordLeftTop;
varying vec4 v_TexCoordRightBottom;

void main() {
	vec2 vUv = v_TexCoord;
	vec2 vL = v_TexCoordLeftTop.xy;
	vec2 vR = v_TexCoordRightBottom.xy;
	vec2 vT = v_TexCoordLeftTop.zw;
	vec2 vB = v_TexCoordRightBottom.zw;
	
	float L = texSample2D(g_Texture0, vL).x;
	float R = texSample2D(g_Texture0, vR).x;
	float T = texSample2D(g_Texture0, vT).y;
	float B = texSample2D(g_Texture0, vB).y;
	vec2 C = texSample2D(g_Texture0, vUv).xy;
	if (vL.x < 0.0) { L = -C.x; }
	if (vR.x > 1.0) { R = -C.x; }
	if (vT.y > 1.0) { T = -C.y; }
	if (vB.y < 0.0) { B = -C.y; }
	float div = 0.5 * (R - L + T - B);
	gl_FragColor = vec4(div, 0.0, 0.0, 1.0);
}
