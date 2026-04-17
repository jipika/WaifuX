
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":9}
// [COMBO] {"material":"ui_editor_properties_pulse_alpha","combo":"PULSEALPHA","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_pulse_color","combo":"PULSECOLOR","type":"options","default":1}

#include "common_blending.h"

varying vec4 v_TexCoord;

varying float v_Pulse;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_noise","default":"util/noise"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float g_Time;

uniform float g_PulseSpeed; // {"material":"speed","label":"ui_editor_properties_pulse_speed","default":3,"range":[0,10]}
uniform float g_PulsePhase; // {"material":"phase","label":"ui_editor_properties_pulse_phase","default":0,"range":[0,6.282]}
uniform float g_PulseAmount; // {"material":"amount","label":"ui_editor_properties_pulse_amount","default":1,"range":[0,2]}
uniform vec2 g_PulseThresholds; // {"material":"bounds","label":"ui_editor_properties_pulse_bounds","default":"0 1"}

uniform float g_NoiseSpeed; // {"material":"noisespeed","label":"ui_editor_properties_noise_speed","default":0.5,"range":[0,1.0]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0,"range":[0,2]}

uniform float g_Power; // {"material":"power","label":"ui_editor_properties_power","default":1,"range":[0,4]}
uniform vec3 g_TintColor1; // {"material":"tintlow","label":"ui_editor_properties_tint_low", "type": "color", "default":"1 1 1"}
uniform vec3 g_TintColor2; // {"material":"tinthigh","label":"ui_editor_properties_tint_high", "type": "color", "default":"1 1 1"}

void main() {
	vec4 sample = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 albedo = sample;
	float pulse = 0.0;

	pulse = v_Pulse;

#if AUDIOPROCESSING == 0
	pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y, sin(g_Time * g_PulseSpeed + (g_PulsePhase - 1.57079632679)) * 0.5 + 0.5) * g_PulseAmount;
	float noise = texSample2D(g_Texture1, vec2(g_Time * 0.08333333, g_Time * 0.02777777) * g_NoiseSpeed).r * g_NoiseAmount;
	
	pulse += noise;
	pulse = pow(pulse, g_Power);
#endif

#if PULSECOLOR
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb * g_TintColor1, albedo.rgb * g_TintColor2, pulse);
#endif

#if PULSEALPHA
	albedo.a *= pulse;
#endif

#if MASK
	float mask = texSample2D(g_Texture2, v_TexCoord.zw).r;
	albedo = mix(sample, albedo, mask);
#endif

	gl_FragColor = vec4(max(CAST3(0), albedo.rgb), albedo.a);
}
