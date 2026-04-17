
#include "common.h"
#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;

uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0 0"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"1 0"}
uniform vec2 g_Point2; // {"material":"point2","label":"p2","default":"1 1"}
uniform vec2 g_Point3; // {"material":"point3","label":"p3","default":"0 1"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec3 v_TexCoord;

void main() {
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));

	v_TexCoord = mul(vec3(a_TexCoord.xy, 1.0), xform);

	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
}
