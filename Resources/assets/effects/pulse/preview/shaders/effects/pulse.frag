
// [COMBO] {"material":"Blend mode","combo":"BLENDMODE","type":"imageblending","default":9}
// [COMBO] {"material":"Pulse alpha","combo":"PULSEALPHA","type":"options","default":0}
// [COMBO] {"material":"Pulse color","combo":"PULSECOLOR","type":"options","default":1}

#include "common_blending.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Noise","default":"util/noise"}
uniform float g_Time;

uniform float g_PulseSpeed; // {"material":"Pulse speed","default":3,"range":[0,10]}
uniform float g_PulseAmount; // {"material":"Pulse amount","default":1,"range":[0,2]}
uniform vec2 g_PulseThresholds; // {"material":"Pulse bounds","default":"0 1"}

uniform float g_NoiseSpeed; // {"material":"Noise speed","default":0.1,"range":[0,0.5]}
uniform float g_NoiseAmount; // {"material":"Noise amount","default":0,"range":[0,2]}

uniform float g_Power; // {"material":"Power","default":1,"range":[0,4]}
uniform vec3 g_TintColor1; // {"material":"Tint low", "type": "color", "default":"1 1 1"}
uniform vec3 g_TintColor2; // {"material":"Tint high", "type": "color", "default":"1 1 1"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	//float delta = length(g_KeyColor - albedo.rgb); // [0, SQRT_3]
	//float blend = smoothstep(0.001, 0.002 + g_KeyFuzz, delta - g_KeyTolerance);
	//albedo.a *= mix(g_KeyAlpha, 1.0, blend);
	
	float pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y, sin(g_Time * g_PulseSpeed) * 0.5 + 0.5) * g_PulseAmount;
	float noise = texSample2D(g_Texture1, vec2(g_Time, g_Time * 0.333) * g_NoiseSpeed).r * g_NoiseAmount;
	
	pulse += noise;
	pulse = pow(pulse, g_Power);
	
#if PULSECOLOR
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb * g_TintColor1, albedo.rgb * g_TintColor2, pulse);
#endif

#if PULSEALPHA
	albedo.a *= pulse;
#endif


	gl_FragColor = saturate(albedo);
}
