
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}

#include "common.h"
#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;


attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if PERSPECTIVE == 0
varying vec2 v_ReflectedCoord;
uniform float g_Direction; // {"material":"direction","label":"ui_editor_properties_direction","default":0,"range":[0,6.28],"direction":true}
uniform float g_ReflectionOffset; // {"material":"offset","label":"ui_editor_properties_offset","default":0.0,"range":[-1,1]}
#else
uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0 0"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"1 0"}
uniform vec2 g_Point2; // {"material":"point2","label":"p2","default":"1 1"}
uniform vec2 g_Point3; // {"material":"point3","label":"p3","default":"0 1"}

varying vec3 v_TexCoordPerspective;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
#if MASK
	v_TexCoord.z *= g_Texture1Resolution.z / g_Texture1Resolution.x;
	v_TexCoord.w *= g_Texture1Resolution.w / g_Texture1Resolution.y;
#endif

#if PERSPECTIVE == 0
	vec2 center = vec2(0.5, 0.5);
	vec2 delta = a_TexCoord - center;
	delta.y += g_ReflectionOffset;
	delta.y = -delta.y;
	
	delta = rotateVec2(delta, g_Direction);
	v_ReflectedCoord = center + delta;
#else
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif
}
