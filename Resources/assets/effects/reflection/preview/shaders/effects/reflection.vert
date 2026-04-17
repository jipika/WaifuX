
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

uniform float g_Direction; // {"material":"Direction","default":0,"range":[0,6.28]}
uniform float g_ReflectionOffset; // {"material":"Offset","default":0.0,"range":[-1,1]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_ReflectedCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
	
	vec2 center = vec2(0.5, 0.5);
	vec2 delta = a_TexCoord - center;
	delta.y += g_ReflectionOffset;
	delta.y = -delta.y;
	
	delta = rotateVec2(delta, g_Direction);
	v_ReflectedCoord = center + delta;
}
