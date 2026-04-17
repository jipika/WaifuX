
// [COMBO] {"material":"Mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

uniform float g_Top; // {"material":"Top","default":0.0,"range":[-2,2]}
uniform float g_Bottom; // {"material":"Bottom","default":0.0,"range":[-2,2]}
uniform float g_Left; // {"material":"Left","default":0.0,"range":[-2,2]}
uniform float g_Right; // {"material":"Right","default":0.0,"range":[-2,2]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

void main() {

	vec3 position = a_Position;
	
#if MODE == 1
	vec2 textureScale = g_Texture0Resolution.zw;
	position.x += textureScale.x * 1.0 * (step(a_TexCoord.y, 0.5) * g_Top +
					step(0.5, a_TexCoord.y) * g_Bottom);
	position.y += textureScale.y * 1.0 * (step(a_TexCoord.x, 0.5) * g_Left +
					step(0.5, a_TexCoord.x) * g_Right);
#endif
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	
	v_TexCoord.xy = a_TexCoord;

#if MODE == 0
	v_TexCoord.x -= step(a_TexCoord.y, 0.5) * g_Top +
					step(0.5, a_TexCoord.y) * g_Bottom;
	v_TexCoord.y += step(a_TexCoord.x, 0.5) * g_Left +
					step(0.5, a_TexCoord.x) * g_Right;
#endif
}
