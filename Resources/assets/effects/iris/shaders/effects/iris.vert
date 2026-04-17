
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":"1 1","linked":true,"range":[0.01, 10.0]}
uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.01, 2.0]}
uniform float g_Rough; // {"material":"rough","label":"ui_editor_properties_smoothness","default":0.2,"range":[0.01, 1.0]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.5,"range":[0.01, 2.0]}
uniform float g_PhaseOffset; // {"material":"phase", "label":"ui_editor_properties_phase", "default":0,"range":[-1, 1]}

#if MASK
uniform vec4 g_Texture1Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_TexCoordIris;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
#if MASK
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif
	float time = (g_Time * g_Speed) + g_PhaseOffset;

	float lowDt = floor(time);
	vec2 motion2 = sin(1.9 * (lowDt + vec2(0, 1)));
	vec4 motion4 = sin(2.5 * (lowDt + vec4(0, 0, 1, 1)) + vec4(1, 2, 1, 2));
	vec2 moveStart = motion2.xx + motion4.xy;
	vec2 moveEnd = motion2.yy + motion4.zw;
	vec2 da = mix(moveStart, moveEnd, smoothstep(1 - g_Rough, 1, cos(frac(time) * M_PI) * -0.5 + 0.5));

	da.x += sin(time) * g_NoiseAmount;
	da.y += cos(time) * g_NoiseAmount;
	
	da *= g_Scale * 0.001;
	v_TexCoordIris = da.xy;
}
