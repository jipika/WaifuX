
// [COMBO] {"material":"ui_editor_properties_edges","combo":"EDGES","type":"options","default":4,"options":{"2":2,"3":3,"4":4,"5":5}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;
uniform float g_Time;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform float g_Direction; // {"material":"ui_editor_properties_direction","default":0,"range":[0,6.28]}
uniform float g_Speed; // {"material":"ui_editor_properties_speed","default":0,"range":[-1,1]}

varying vec4 v_TexCoord01;
varying vec4 v_TexCoord23;
varying vec4 v_TexCoord45;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	v_TexCoord01.xy = a_TexCoord;
	
	vec2 baseDirection = rotateVec2(vec2(0, 0.5), g_Time * g_Speed);
	float ratio = g_Texture0Resolution.x / g_Texture0Resolution.y;
	
#if EDGES == 2
	v_TexCoord01.zw = rotateVec2(baseDirection, g_Direction);
	v_TexCoord23.xy = CAST2(0.0);
	v_TexCoord23.zw = CAST2(0.0);
	v_TexCoord45.xy = CAST2(0.0);
	v_TexCoord45.zw = CAST2(0.0);
#endif
#if EDGES == 3
	v_TexCoord01.zw = rotateVec2(baseDirection, g_Direction);
	v_TexCoord23.xy = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.3333);
	v_TexCoord23.zw = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.6666);
	v_TexCoord45.xy = CAST2(0.0);
	v_TexCoord45.zw = CAST2(0.0);
#endif
#if EDGES == 4
	v_TexCoord01.zw = rotateVec2(baseDirection, g_Direction);
	v_TexCoord23.xy = rotateVec2(vec2(-baseDirection.y, baseDirection.x), g_Direction);
	v_TexCoord23.zw = CAST2(0.0);
	v_TexCoord45.xy = CAST2(0.0);
	v_TexCoord45.zw = CAST2(0.0);
#endif
#if EDGES == 5
	v_TexCoord01.zw = rotateVec2(baseDirection, g_Direction);
	v_TexCoord23.xy = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.2);
	v_TexCoord23.zw = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.4);
	v_TexCoord45.xy = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.6);
	v_TexCoord45.zw = rotateVec2(baseDirection, g_Direction + M_PI_2 * 0.8);
#endif
	
	v_TexCoord01.w *= ratio;
	v_TexCoord23.yw *= ratio;
	v_TexCoord45.yw *= ratio;
}
