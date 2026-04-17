
// [COMBO] {"material":"Mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;
uniform vec4 g_Texture1Resolution;

uniform float g_Speed; // {"material":"Speed","default":1.0,"range":[-5,5]}
uniform vec2 g_SpinCenter; // {"material":"Center","default":"0.5 0.5"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if MASK == 1
varying vec2 v_TexCoordMask;
#endif

void main() {

	vec3 position = a_Position;
#if MODE == 1
	position.xy = rotateVec2(position.xy - g_SpinCenter, g_Speed * g_Time) + g_SpinCenter;
#endif
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	v_TexCoord.xyzw = a_TexCoord.xyxy;
	
#if MASK == 1
	v_TexCoordMask = vec2(a_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						a_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

#if MODE == 0
	v_TexCoord.xy = rotateVec2(v_TexCoord.xy - g_SpinCenter, g_Speed * g_Time) + g_SpinCenter;
#endif
}
