
// [COMBO] {"material":"ui_editor_properties_audio_response","combo":"AUDIOPROCESSING","type":"audioprocessingoptions","default":0}

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

#if MASK
uniform vec4 g_Texture2Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying float v_Pulse;

uniform float g_Time;

uniform vec2 g_PulseThresholds; // {"material":"bounds","label":"ui_editor_properties_pulse_bounds","default":"0 1"}
uniform float g_PulseSpeed; // {"material":"speed","label":"ui_editor_properties_pulse_speed","default":3,"range":[0,10]}
uniform float g_PulsePhase; // {"material":"phase","label":"ui_editor_properties_time_offset","default":0,"range":[0,1]}
uniform float g_PulseAmount; // {"material":"amount","label":"ui_editor_properties_pulse_amount","default":1,"range":[0,2]}

#if AUDIOPROCESSING
uniform float g_AudioSpectrum16Left[16];
uniform float g_AudioSpectrum16Right[16];

uniform float g_AudioFrequencyMin; // {"material":"frequencymin","label":"ui_editor_properties_frequency_min","default":0,"int":true,"range":[0,15]}
uniform float g_AudioFrequencyMax; // {"material":"frequencymax","label":"ui_editor_properties_frequency_max","default":1,"int":true,"range":[0,15]}
uniform float g_AudioPower; // {"material":"audioexponent","label":"ui_editor_properties_audio_exponent","default":1.0,"range":[0,4]}
uniform vec2 g_AudioBounds; // {"material":"audiobounds","label":"ui_editor_properties_audio_bounds","default":"0.5 1.0"}
uniform float g_AudioMultiply; // {"material":"audioamount","label":"ui_editor_properties_audio_amount","default":1,"range":[0,2]}

float CreateAudioResponse(float bufferLeft[16], float bufferRight[16])
{
	float audioFrequencyEnd = max(g_AudioFrequencyMin, g_AudioFrequencyMax);
	float audioResponse = 0.0;

#if AUDIOPROCESSING == 1
	for (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)
	{
		audioResponse += bufferLeft[a];
	}
	audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0);
#endif
#if AUDIOPROCESSING == 2
	for (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)
	{
		audioResponse += bufferRight[a];
	}
	audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0);
#endif
#if AUDIOPROCESSING == 3
	for (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a)
	{
		audioResponse += bufferLeft[a];
		audioResponse += bufferRight[a];
	}
	audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0) * 2.0;
#endif

	audioResponse = smoothstep(g_AudioBounds.x, g_AudioBounds.y, audioResponse);
	audioResponse = saturate(pow(audioResponse, g_AudioPower)) * g_AudioMultiply;
	return audioResponse;
}
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
#if MASK
	v_TexCoord.zw = vec2(a_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						a_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif

#if AUDIOPROCESSING
	v_Pulse = CreateAudioResponse(g_AudioSpectrum16Left, g_AudioSpectrum16Right);
#else
	v_Pulse = smoothstep(g_PulseThresholds.x, g_PulseThresholds.y,
		sin(g_Time * g_PulseSpeed + (g_PulsePhase - 0.25) * 6.28318530718) * 0.5 + 0.5) * g_PulseAmount;
#endif
}
