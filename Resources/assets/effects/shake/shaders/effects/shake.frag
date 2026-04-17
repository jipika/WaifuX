
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_direction","combo":"DIRECTION","type":"options","default":0,"options":{"ui_editor_properties_center":0,"ui_editor_properties_left":1,"ui_editor_properties_right":2}}

#include "common.h"

varying vec4 v_TexCoord;
varying vec2 v_Bounds;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_shake_direction_map","mode":"flowmask","default":"util/noflow"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_time_offset","mode":"opacitymask","default":"util/black","combo":"TIMEOFFSET"}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_opacity","mode":"opacitymask","combo":"MASK"}
uniform float g_Time;

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.0, 10]}
uniform float g_Amp; // {"material":"strength","label":"ui_editor_properties_strength","default":0.1,"range":[0.01, 0.5]}
uniform vec2 g_Friction; // {"material":"friction","label":"ui_editor_properties_friction","default":"1 1","linked":true,"range":[0.01, 10.0]}

#if AUDIOPROCESSING
varying float v_AudioPulse;
#endif

#if MASK == 1
varying vec4 v_TexCoordMask;
#endif

void main() {
	float flowPhase = 0.0;

#if TIMEOFFSET
	flowPhase = texSample2D(g_Texture2, v_TexCoord.zw).r * M_PI_2;
#endif

	vec2 flowColors = texSample2D(g_Texture1, v_TexCoord.zw).rg;
	vec2 flowMask = (flowColors.rg - vec2(0.498, 0.498)) * 2.0;
	float offset = 0.0;
	
#if AUDIOPROCESSING == 0
#if NOISE
	vec4 sines = flowPhase + frac(g_Speed * g_Time / M_PI_2 * vec4(1, -0.16161616, 0.0083333, -0.00019841)) * M_PI_2;
	vec4 csines = cos(sines);
	sines = sin(sines);
	
	vec4 base = step(0.0, csines);
	sines = sines * 0.498 + 0.5;
	sines = mix(1.0 - pow(1.0 - sines, CAST4(g_Friction.x)), pow(sines, CAST4(g_Friction.y)), base);
	offset = dot(CAST4(0.5), sines);
#else
	float time = g_Speed * g_Time + flowPhase;
	offset = sin(frac(time / M_PI_2) * M_PI_2);
	offset = offset * 0.498 + 0.5;
	float base = step(0.0, cos(time));
	offset = mix(1.0 - pow(1.0 - offset, g_Friction.x), pow(offset, g_Friction.y), base);
#endif
	offset = saturate((offset - v_Bounds.x) * v_Bounds.y);
#endif


#if DIRECTION == 0
#if AUDIOPROCESSING
	offset += v_AudioPulse;
#else
	offset = offset * 2.0 - 1.0;
#endif
#endif

#if DIRECTION == 1
#if AUDIOPROCESSING
	offset = 1.0 - v_AudioPulse;
#endif
#endif

#if DIRECTION == 2
#if AUDIOPROCESSING
	offset -= v_AudioPulse;
#else
	offset = offset - 1.0;
#endif
#endif
	
	vec2 texCoordOffset = offset * g_Amp * g_Amp * flowMask;
	gl_FragColor = texSample2D(g_Texture0, texCoordOffset + v_TexCoord.xy);
	
#if MASK
	// Only allow sampling from mask
	float mask = texSample2D(g_Texture3, texCoordOffset * v_TexCoordMask.zw + v_TexCoordMask.xy).r;
	gl_FragColor = mix(texSample2D(g_Texture0, v_TexCoord.xy), gl_FragColor, mask);
#endif
}
