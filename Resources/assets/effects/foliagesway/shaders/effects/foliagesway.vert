
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.01, 10]}
uniform float g_Strength; // {"material":"strength","label":"ui_editor_properties_strength","default":0.4,"range":[0.01, 1]}
uniform float g_Phase; // {"material":"phase","label":"ui_editor_properties_phase","default":0,"range":[0, 6.28]}
uniform float g_Power; // {"material":"power","label":"ui_editor_properties_power","default":1,"range":[0.01, 2]}
uniform vec2 g_DirectionWeights; // {"material":"directionweights","label":"ui_editor_properties_direction_weights","default":"1 0.2"}
uniform vec4 g_CornerWeights; // {"material":"cornerweights","label":"ui_editor_properties_corner_weights","default":"1 1 0 0"}

uniform vec2 g_Bounds; // {"material":"bounds","label":"ui_editor_properties_bounds","default":"0 1"}
uniform float g_NoiseScale; // {"material":"scale","label":"ui_editor_properties_scale","default":0.05,"range":[0.0, 1.0]}
uniform float g_Ratio; // {"material":"ratio","label":"ui_editor_properties_ratio","default":0.3,"range":[0.01,10]}
uniform float g_Direction; // {"material":"scrolldirection","label":"ui_editor_properties_direction","default":0,"range":[0,6.28],"direction":true}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

#if MODE == 0
varying vec4 v_TexCoordNoise;
varying vec3 v_Params;
uniform vec4 g_Texture0Resolution;
#endif

varying vec4 v_TexCoord;

#if MASK == 1
uniform vec4 g_Texture1Resolution;
#endif

void main() {
	v_TexCoord.zw = CAST2(0.0);
	
#if MODE == 0
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
#if MASK == 1
	v_TexCoord.zw = vec2(a_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						a_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif
	
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w * g_Ratio;
	v_TexCoordNoise.zw = rotateVec2(vec2(1.0 / aspect, aspect), g_Direction);
	v_TexCoordNoise.xy = a_TexCoord.xy * g_NoiseScale; // rotateVec2(vec2(a_TexCoord.x, -a_TexCoord.y), g_Direction);
	//v_TexCoordNoise = vec2(v_TexCoordNoise.x * aspect * g_Ratio, v_TexCoordNoise.y) * g_NoiseScale;
	
	v_Params.xy = rotateVec2(a_TexCoord.xy, g_Direction);
	v_Params.z = g_Strength * g_Strength * 0.005;
#else
	vec3 position = a_Position;
	
	vec4 sines = g_Phase + g_Speed * g_Time * vec4(1, -0.16161616, 0.0083333, -0.00019841);
	sines = sin(sines);
	vec4 csines = 0.4 + g_Phase + g_Speed * g_Time * vec4(-0.5, 0.041666666, -0.0013888889, 0.000024801587);
	csines = sin(csines);
	
	sines = pow(abs(sines), CAST4(g_Power)) * sign(sines);
	csines = pow(abs(csines), CAST4(g_Power)) * sign(csines);
	
	float weight = saturate(g_CornerWeights.x * (1.0 - a_TexCoord.x) * (1.0 - a_TexCoord.y) +
					g_CornerWeights.y * (a_TexCoord.x) * (1.0 - a_TexCoord.y) +
					g_CornerWeights.z * (a_TexCoord.x) * (a_TexCoord.y) +
					g_CornerWeights.w * (1.0 - a_TexCoord.x) * (a_TexCoord.y));
	
	position.x += dot(sines, CAST4(1.0)) * g_Strength * 100.0 * weight * g_DirectionWeights.x;
	position.y += dot(csines, CAST4(1.0)) * g_Strength * 100.0 * weight * g_DirectionWeights.y;
	
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
#endif
	v_TexCoord.xy = a_TexCoord;
}
