
#include "common.h"
#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;

uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0.67728 0.01297"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"0.76007 0.14043"}
uniform vec2 g_Point2; // {"material":"point2","label":"p2","default":"0.46654 1.09592"}
uniform vec2 g_Point3; // {"material":"point3","label":"p3","default":"0.16363 0.44881"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec3 v_TexCoordFx;

void main() {
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));

	v_TexCoord.xy = a_TexCoord.xy;
	v_TexCoordFx = mul(vec3(a_TexCoord.xy, 1.0), xform);

	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
}
