
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform float u_direction; // {"material":"ui_editor_properties_direction","default":1.57079632679,"direction":true,"conversion":"rad2deg"}
uniform float u_speed; // {"material":"ui_editor_properties_speed","default":0.02,"range":[0,0.1]}
uniform float u_scale; // {"material":"ui_editor_properties_granularity","default":2,"range":[0,4]}
uniform float u_scaleX; // {"material":"ui_editor_properties_granularity_horizontal","default":0.5,"range":[0,1]}

uniform vec4 g_Texture0Resolution;

#if MASK
uniform vec4 g_Texture1Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_NoiseCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xyzw = a_TexCoord.xyxy;

#if MASK
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

	v_NoiseCoord = v_TexCoord;
	v_NoiseCoord.x *= g_Texture0Resolution.x / g_Texture0Resolution.y;
	v_NoiseCoord = rotateVec2(v_NoiseCoord, -u_direction + 1.57079632679);

	v_NoiseCoord *= u_scale;
	v_NoiseCoord.x *= u_scaleX;
	v_NoiseCoord.x += g_Time * u_speed;
}
