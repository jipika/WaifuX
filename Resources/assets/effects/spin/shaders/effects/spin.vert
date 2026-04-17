
// [COMBO] {"material":"ui_editor_properties_elliptical","combo":"ELLIPTICAL","type":"options","default":1}
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":0}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;
uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1.0,"range":[-5,5]}
uniform vec2 g_SpinCenter; // {"material":"center","label":"ui_editor_properties_center","default":"0.5 0.5","position":true}
uniform float g_Ratio; // {"material":"ratio","label":"ui_editor_properties_ratio","default":1.0,"range":[0,10]}
uniform float g_Axis; // {"material":"angle","label":"ui_editor_properties_angle","default":0.0,"range":[0,3.141]}
uniform float g_Phase; // {"material":"phase","label":"ui_editor_properties_time_offset","default":0.0,"range":[0,1]}

uniform vec2 g_Friction; // {"material":"friction","label":"ui_editor_properties_friction","default":"1 1","linked":true,"range":[0.01, 10.0]}
uniform float g_NoiseSpeed; // {"material":"noisespeed","label":"ui_editor_properties_noise_speed","default":5,"range":[-10,10]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":1,"range":[0,5]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_TexCoordSoftMask;

#if MASK == 1
varying vec2 v_TexCoordMask;
#endif

void main() {

	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	vec3 position = a_Position;

	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	v_TexCoord.xyzw = a_TexCoord.xyxy;
	
#if MASK == 1
	v_TexCoordMask = vec2(a_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						a_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

	v_TexCoord.xy -= g_SpinCenter;
	v_TexCoord.x *= aspect;

#if ELLIPTICAL
	v_TexCoord.xy = rotateVec2(v_TexCoord.xy, g_Axis);
	v_TexCoord.x *= g_Ratio;
#endif
	v_TexCoordSoftMask.xy = v_TexCoord.xy;

	float offset = g_Phase * 6.28318530718;
#if NOISE
	vec4 sines = frac(g_NoiseSpeed * g_Time / M_PI_2 * vec4(1, -0.16161616, 0.0083333, -0.00019841)) * M_PI_2;
	vec4 csines = cos(sines);
	sines = sin(sines);
	
	vec4 base = step(0.0, csines);
	sines = sines * 0.498 + 0.5;
	sines = mix(1.0 - pow(1.0 - sines, CAST4(g_Friction.x)), pow(sines, CAST4(g_Friction.y)), base);
	offset += (dot(CAST4(0.5), sines) - 1.0) * g_NoiseAmount;
#endif
	
	v_TexCoord.xy = rotateVec2(v_TexCoord.xy, g_Speed * g_Time + offset);
	
#if ELLIPTICAL
	v_TexCoord.x /= g_Ratio;
	v_TexCoord.xy = rotateVec2(v_TexCoord.xy, -g_Axis);
	
	v_TexCoordSoftMask.xy = rotateVec2(v_TexCoordSoftMask.xy, -g_Axis);
#endif

	v_TexCoord.x /= aspect;
	v_TexCoord.xy += g_SpinCenter;
	
	v_TexCoordSoftMask.xy += g_SpinCenter;
}
