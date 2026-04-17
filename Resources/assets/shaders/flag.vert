
#include "common_vertex.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec4 v_NormalCoord;

uniform float g_WaveSpeed; // {"material":"Speed","default":0.4}

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	
	v_NormalCoord.xy = a_TexCoord * vec2(1, 0.3) * 0.7;
	v_NormalCoord.x -= g_Time * g_WaveSpeed;

	v_NormalCoord.zw = a_TexCoord * vec2(1, 0.7) * 0.3;
	v_NormalCoord.z -= g_Time * g_WaveSpeed * 0.5;
}
