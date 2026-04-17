// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}

#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;

#if MASK
uniform vec4 g_Texture1Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if PERSPECTIVE == 1
uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0 0"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"1 0"}
uniform vec2 g_Point2; // {"material":"point2","label":"p2","default":"1 1"}
uniform vec2 g_Point3; // {"material":"point3","label":"p3","default":"0 1"}
varying vec3 v_TexCoordPerspective;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xyzw = a_TexCoord.xyxy;

#if MASK
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

#if PERSPECTIVE == 1
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif
}
