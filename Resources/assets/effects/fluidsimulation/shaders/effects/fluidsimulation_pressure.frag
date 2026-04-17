
uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}

varying vec2 v_TexCoord;
varying vec4 v_TexCoordLeftTop;
varying vec4 v_TexCoordRightBottom;

void main() {
	vec2 vUv = v_TexCoord;
	vec2 vL = v_TexCoordLeftTop.xy;
	vec2 vR = v_TexCoordRightBottom.xy;
	vec2 vT = v_TexCoordLeftTop.zw;
	vec2 vB = v_TexCoordRightBottom.zw;

	float L = texSample2D(g_Texture1, vL).x;
	float R = texSample2D(g_Texture1, vR).x;
	float T = texSample2D(g_Texture1, vT).x;
	float B = texSample2D(g_Texture1, vB).x;
	float C = texSample2D(g_Texture1, vUv).x;
	float divergence = texSample2D(g_Texture0, vUv).x;
	float pressure = (L + R + B + T - divergence) * 0.25;
	gl_FragColor = vec4(pressure, 0.0, 0.0, 1.0);
}
