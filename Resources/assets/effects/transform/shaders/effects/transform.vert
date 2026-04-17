
// [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;

uniform vec2 g_Offset; // {"material":"offset","label":"ui_editor_properties_offset","default":"0 0"}
uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":"1 1"}
uniform float g_Direction; // {"material":"angle","label":"ui_editor_properties_angle","default":0,"range":[0,6.28],"direction":true,"conversion":"rad2deg"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

vec2 applyFx(vec2 v) {
	v = rotateVec2(v - CAST2(0.5), -g_Direction);
	return (v + g_Offset) * g_Scale + CAST2(0.5);
}

void main() {

	vec3 position = a_Position;
#if MODE == 1
	position.xy = applyFx(position.xy);
#endif
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	v_TexCoord = a_TexCoord;
	
#if MODE == 0
	v_TexCoord = applyFx(v_TexCoord);
#endif
}
