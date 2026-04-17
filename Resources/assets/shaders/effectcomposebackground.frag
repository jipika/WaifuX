
varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true,"default":"_rt_FullFrameBuffer"}

void main() {
	vec4 result = texSample2D(g_Texture0, v_TexCoord);

	vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * CAST2(0.5) + 0.5;
	vec4 bg = texSample2D(g_Texture1, screenCoord.xy);

	gl_FragColor.rgb = mix(bg.rgb, result.rgb, result.a);
	gl_FragColor.a = 1.0;
}
