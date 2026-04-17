
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/white"}

uniform float g_Threshold; // {"material":"Ray threshold","default":0.5,"range":[0, 1]}

void main() {
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	vec4 sample = texSample2D(g_Texture0, v_TexCoord.xy);
	sample.rgb *= sample.a;
	sample.a = 1.0;
	gl_FragColor = sample * mask * step(g_Threshold, dot(vec3(0.11, 0.59, 0.3), sample.rgb));
}
