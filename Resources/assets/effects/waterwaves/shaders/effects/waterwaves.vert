
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_dual_waves","combo":"DUALWAVES","type":"options","default":0}

#include "common.h"
#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;
uniform vec4 g_Texture1Resolution;
uniform vec4 g_Texture2Resolution;
uniform float g_Direction; // {"material":"direction","label":"ui_editor_properties_direction","default":0,"direction":true,"group":"ui_editor_properties_wave"}

#if DUALWAVES == 1
uniform float g_Direction2; // {"material":"direction2","label":"direction2","default":0,"direction":true,"group":"ui_editor_properties_wave_2"}
varying vec2 v_Direction2;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_Direction;

#if PERSPECTIVE == 1
uniform vec2 g_Point0; // {"default":"0 0","label":"p0","material":"point0"}
uniform vec2 g_Point1; // {"default":"1 0","label":"p1","material":"point1"}
uniform vec2 g_Point2; // {"default":"1 1","label":"p2","material":"point2"}
uniform vec2 g_Point3; // {"default":"0 1","label":"p3","material":"point3"}

varying vec3 v_TexCoordPerspective;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;

#if MASK
	v_TexCoord.z *= g_Texture1Resolution.z / g_Texture1Resolution.x;
	v_TexCoord.w *= g_Texture1Resolution.w / g_Texture1Resolution.y;
#else
#if TIMEOFFSET
	v_TexCoord.z *= g_Texture2Resolution.z / g_Texture2Resolution.x;
	v_TexCoord.w *= g_Texture2Resolution.w / g_Texture2Resolution.y;
#endif
#endif

	v_Direction = rotateVec2(vec2(0, 1), g_Direction);

#if DUALWAVES == 1
	v_Direction2 = rotateVec2(vec2(0, 1), g_Direction2);
#endif

#if PERSPECTIVE == 1
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective.xyz = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif
}
