
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":1}

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white"}

uniform float g_Threshold; // {"material":"ui_editor_properties_ray_threshold","default":0.5,"range":[0, 1]}

#if NOISE == 1
varying vec4 v_NoiseTexCoord;

uniform sampler2D g_Texture2; // {"material":"ui_editor_properties_albedo","default":"util/clouds_256"}
uniform float g_NoiseAmount; // {"material":"ui_editor_properties_noise_amount","default":0.4,"range":[0.01, 1]}
#endif

void main() {
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	vec4 sample = texSample2D(g_Texture0, v_TexCoord.xy);
	
#if NOISE == 1
	float noiseSample = texSample2D(g_Texture2, v_NoiseTexCoord.xy).r * texSample2D(g_Texture2, v_NoiseTexCoord.zw).r;
	noiseSample = mix(sample.a, sample.a * noiseSample, g_NoiseAmount);
#endif
	
	sample.rgb *= sample.a;
	sample.a = 1.0;
	
	gl_FragColor = sample * mask * step(g_Threshold, dot(vec3(0.11, 0.59, 0.3), sample.rgb));

#if NOISE == 1
	gl_FragColor.a *= noiseSample;
#endif
}
