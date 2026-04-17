
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}

#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

#if MASK == 1
uniform vec4 g_Texture2Resolution;
#endif


attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if PERSPECTIVE == 0
varying vec4 v_TexCoordClouds;
uniform float g_Time;
uniform vec2 g_CloudSpeeds; // {"material":"speed","label":"ui_editor_properties_speed","default":"0.01 -0.02"}
uniform vec4 g_CloudScales; // {"material":"scale","label":"ui_editor_properties_scale","default":"1.3 1.3 0.5 0.5"}
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
	
#if PERSPECTIVE == 0
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	v_TexCoordClouds.xy = (a_TexCoord + g_Time * g_CloudSpeeds.x) * g_CloudScales.xy;
	v_TexCoordClouds.zw = (a_TexCoord + g_Time * g_CloudSpeeds.y) * g_CloudScales.zw;
	v_TexCoordClouds.xz *= aspect;
	v_TexCoordClouds.zw = vec2(-v_TexCoordClouds.w, v_TexCoordClouds.z);
#else
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif
	
#if MASK == 1
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
