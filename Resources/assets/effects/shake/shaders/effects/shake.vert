
// [COMBO] {"material":"ui_editor_properties_audio_response","combo":"AUDIOPROCESSING","type":"audioprocessingoptions","default":0}

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

#if MASK == 1
uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture3Resolution;
varying vec4 v_TexCoordMask;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform vec2 g_Bounds; // {"material":"bounds","label":"ui_editor_properties_bounds","default":"0 1"}

varying vec4 v_TexCoord;
varying vec2 v_Bounds;

#if AUDIOPROCESSING
varying float v_AudioPulse;
uniform float g_AudioSpectrum16Left[16];
uniform float g_AudioSpectrum16Right[16];

uniform float g_AudioFrequencyMin; // {"material":"frequencymin","label":"ui_editor_properties_frequency_min","default":0,"int":true,"range":[0,15]}
uniform float g_AudioFrequencyMax; // {"material":"frequencymax","label":"ui_editor_properties_frequency_max","default":1,"int":true,"range":[0,15]}
uniform float g_AudioPower; // {"material":"audioexponent","label":"ui_editor_properties_audio_exponent","default":1.0,"range":[0,4]}
uniform vec2 g_AudioBounds; // {"material":"audiobounds","label":"ui_editor_properties_audio_bounds","default":"0.0 1.2"}
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
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
	v_Bounds.x = g_Bounds.x;
	v_Bounds.y = 1.0 / (g_Bounds.y - g_Bounds.x);

#if AUDIOPROCESSING
	v_AudioPulse = CreateAudioResponse(g_AudioSpectrum16Left, g_AudioSpectrum16Right);
#endif

#if MASK == 1
	v_TexCoordMask.xy = vec2(a_TexCoord.x * g_Texture3Resolution.z / g_Texture3Resolution.x,
						a_TexCoord.y * g_Texture3Resolution.w / g_Texture3Resolution.y);
	v_TexCoordMask.zw = vec2(g_Texture3Resolution.z / g_Texture3Resolution.x, g_Texture3Resolution.w / g_Texture3Resolution.y);
#endif
}
