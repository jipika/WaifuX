
// [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

uniform float g_Top; // {"material":"ui_editor_properties_top","default":0,"range":[-0.49,0.49]}
uniform float g_Bottom; // {"material":"ui_editor_properties_bottom","default":0,"range":[-0.49,0.49]}
uniform float g_Left; // {"material":"ui_editor_properties_left","default":0,"range":[-0.49,0.49]}
uniform float g_Right; // {"material":"ui_editor_properties_right","default":0,"range":[-0.49,0.49]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec3 v_TexCoord;


void main() {

	vec3 position = a_Position;
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.z = 1.0;
	
#if MODE == 1
	position.x += mix(g_Texture0Resolution.z * g_Top * mix(-1.0, 1.0, step(a_TexCoord.x, 0.5)),
					g_Texture0Resolution.z * g_Bottom * mix(-1.0, 1.0, step(a_TexCoord.x, 0.5)),
					step(0.5, a_TexCoord.y));
    
	position.y += mix(g_Texture0Resolution.w * -g_Left * mix(-1.0, 1.0, step(a_TexCoord.y, 0.5)),
					g_Texture0Resolution.w * -g_Right * mix(-1.0, 1.0, step(a_TexCoord.y, 0.5)),
					step(0.5, a_TexCoord.x));
	
#endif
	
	vec2 p3 = vec2(g_Top, g_Left);
	vec2 p2 = vec2(1 - g_Top, g_Right);
	vec2 p1 = vec2(1 - g_Bottom, 1 - g_Right);
	vec2 p0 = vec2(g_Bottom, 1 - g_Left);
	
	float ax = p2.x - p0.x;
	float ay = p2.y - p0.y;
	float bx = p3.x - p1.x;
	float by = p3.y - p1.y;

	float cross = ax * by - ay * bx;

	float cy = p0.y - p1.y;
	float cx = p0.x - p1.x;

	float s = (ax * cy - ay * cx) / cross;

	float t = (bx * cy - by * cx) / cross;

	float q0 = 1 / (1 - t);
	float q1 = 1 / (1 - s);
	float q2 = 1 / t;
	float q3 = 1 / s;

	float q = mix(
				mix(q3, q2, a_TexCoord.x),
				mix(q0, q1, a_TexCoord.x),
				a_TexCoord.y
				);

	v_TexCoord.xy = a_TexCoord;
	
	#if MODE == 0
	v_TexCoord -= 0.5;
	v_TexCoord.x *= 0.5 / (0.5 - mix(g_Top, g_Bottom, step(0.5, a_TexCoord.y)));
	v_TexCoord.y *= 0.5 / (0.5 - mix(g_Left, g_Right, step(0.5, a_TexCoord.x)));
	v_TexCoord += 0.5;
	#endif
	
	v_TexCoord.xy *= q;
	v_TexCoord.z = q;
				
	
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	
	
}
