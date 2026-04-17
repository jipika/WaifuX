
// [COMBO] {"material":"Mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

uniform float g_Top; // {"material":"Top","default":0,"range":[-0.49,0.49]}
uniform float g_Bottom; // {"material":"Bottom","default":0,"range":[-0.49,0.49]}
uniform float g_Left; // {"material":"Left","default":0,"range":[-0.49,0.49]}
uniform float g_Right; // {"material":"Right","default":0,"range":[-0.49,0.49]}

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
	
	float p3x = g_Top;
	float p3y = g_Left;
	
	float p2x = 1 - g_Top;
	float p2y = g_Right;
	
	float p1x = 1 - g_Bottom;
	float p1y = 1 - g_Right;
	
	float p0x = g_Bottom;
	float p0y = 1 - g_Left;
	
	float ax = p2x - p0x;
	float ay = p2y - p0y;
	float bx = p3x - p1x;
	float by = p3y - p1y;

	float cross = ax * by - ay * bx;

	//if (cross != 0) {
		float cy = p0y - p1y;
		float cx = p0x - p1x;

		float s = (ax * cy - ay * cx) / cross;

		//if (s > 0 && s < 1) {
			float t = (bx * cy - by * cx) / cross;

			//if (t > 0 && t < 1) {
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
				
				
			//}
		//}
	//}
	
	
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	
	
	
}
