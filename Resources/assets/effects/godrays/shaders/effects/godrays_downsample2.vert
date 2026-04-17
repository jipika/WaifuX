
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;

#if NOISE == 1
varying vec4 v_NoiseTexCoord;
#endif

uniform float g_Time;
uniform float g_NoiseSpeed; // {"material":"noisespeed","label":"ui_editor_properties_noise_speed","default":0.15,"range":[0.01, 1]}
uniform float g_NoiseScale; // {"material":"noisescale","label":"ui_editor_properties_noise_scale","default":3,"range":[0.01, 10]}

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord = a_TexCoord.xyxy;

#if MASK
	v_TexCoord.z *= g_Texture1Resolution.z / g_Texture1Resolution.x;
	v_TexCoord.w *= g_Texture1Resolution.w / g_Texture1Resolution.y;
#endif

#ifdef HLSL_SM30
	vec2 offsets = 0.5 / g_Texture0Resolution.xy;
	v_TexCoord.xy += offsets;
#endif
	
#if NOISE == 1
	v_NoiseTexCoord.xy = a_TexCoord + g_Time * g_NoiseSpeed;
	v_NoiseTexCoord.wz = vec2(a_TexCoord.y, -a_TexCoord.x) * 0.633 + vec2(-g_Time, g_Time) * 0.5 * g_NoiseSpeed;
	v_NoiseTexCoord *= g_NoiseScale;
#endif
}
