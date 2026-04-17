
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","type":"options","default":0}

#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

#if PERSPECTIVE == 1
uniform vec2 g_Point0; // {"hidden":true,"material":"point0","label":"p0","default":"0 0"}
uniform vec2 g_Point1; // {"hidden":true,"material":"point1","label":"p1","default":"1 0"}
uniform vec2 g_Point2; // {"hidden":true,"material":"point2","label":"p2","default":"1 1"}
uniform vec2 g_Point3; // {"hidden":true,"material":"point3","label":"p3","default":"0 1"}
varying vec3 v_TexCoordPerspective;
#endif

#if LIGHTING
uniform mat4 g_EffectModelMatrix;
uniform mat4 g_EffectModelViewProjectionMatrixInverse;
uniform vec3 g_LightsPosition[4];

varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xy;

#if PERSPECTIVE == 1
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif

#if LIGHTING
	vec4 worldPos = mul(vec4(a_Position, 1.0), g_EffectModelMatrix);

	v_Light0DirectionL3X.xyz = g_LightsPosition[0] - worldPos.xyz;
	v_Light1DirectionL3Y.xyz = g_LightsPosition[1] - worldPos.xyz;
	v_Light2DirectionL3Z.xyz = g_LightsPosition[2] - worldPos.xyz;
	vec3 l3 = g_LightsPosition[3] - worldPos.xyz;

	v_Light0DirectionL3X.w = l3.x;
	v_Light1DirectionL3Y.w = l3.y;
	v_Light2DirectionL3Z.w = l3.z;
#endif
}
