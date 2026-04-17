
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":1}

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_Threshold; // {"material":"raythreshold","label":"ui_editor_properties_ray_threshold","default":0.5,"range":[0, 1]}

#if NOISE == 1
varying vec4 v_NoiseTexCoord;

uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_noise","default":"util/clouds_256"}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.4,"range":[0.01, 1]}
uniform float g_NoiseSmoothness; // {"material":"noisesmoothness","label":"ui_editor_properties_noise_smoothness","default":0.2,"range":[0.01, 0.5]}
#endif

void main() {
#if MASK
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1.0;
#endif
	vec4 sample = texSample2D(g_Texture0, v_TexCoord.xy);
	
#if NOISE
	float noiseSample = texSample2D(g_Texture2, v_NoiseTexCoord.xy).r * texSample2D(g_Texture2, v_NoiseTexCoord.zw).r;
	noiseSample = mix(sample.a, sample.a * noiseSample, g_NoiseAmount);
#endif
	
	sample.rgb *= sample.a;
	sample.a = 1.0;
	
	gl_FragColor = sample * mask * step(g_Threshold, dot(vec3(0.11, 0.59, 0.3), sample.rgb));

#if NOISE
	gl_FragColor.a *= smoothstep(0.5 - g_NoiseSmoothness, 0.5 + g_NoiseSmoothness, noiseSample);
#endif
}
