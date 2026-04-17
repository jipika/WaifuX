
// [COMBO] {"material":"Mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform float g_Speed; // {"material":"Speed","default":1.0,"range":[-5,5]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

void main() {

	vec3 position = a_Position;
#if MODE == 1
	position.xy = rotateVec2(position.xy - CAST2(0.5), g_Speed * g_Time) + CAST2(0.5);
#endif
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	v_TexCoord = a_TexCoord;
	
#if MODE == 0
	v_TexCoord = rotateVec2(v_TexCoord - CAST2(0.5), g_Speed * g_Time) + CAST2(0.5);
#endif
}
