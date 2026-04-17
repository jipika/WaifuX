
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}

#include "common.h"
#include "common_perspective.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

#if MASK
uniform vec4 g_Texture2Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if PERSPECTIVE == 0
varying vec4 v_TexCoordRipple;

uniform vec4 g_Texture0Resolution;
uniform float g_Time;
uniform float g_AnimationSpeed; // {"material":"animationspeed","label":"ui_editor_properties_animation_speed","default":0.15,"range":[0,0.5]}
uniform float g_Scale; // {"material":"scale","label":"ui_editor_properties_ripple_scale","default":1,"range":[0,10]}
uniform float g_ScrollSpeed; // {"material":"scrollspeed","label":"ui_editor_properties_scroll_speed","default":0,"range":[0,0.5]}
uniform float g_Direction; // {"material":"scrolldirection","label":"ui_editor_properties_scroll_direction","default":0,"range":[0,6.28],"direction":true,"conversion":"rad2deg"}
uniform float g_Ratio; // {"material":"ratio","label":"ui_editor_properties_ratio","default":1,"range":[0,10]}
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
	vec2 coordsRotated = v_TexCoord.xy;
	vec2 coordsRotated2 = v_TexCoord.xy * 1.333;
	
	vec2 scroll = rotateVec2(vec2(0, 1), g_Direction) * g_ScrollSpeed * g_ScrollSpeed * g_Time;
	
	v_TexCoordRipple.xy = coordsRotated + g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
	v_TexCoordRipple.zw = coordsRotated2 - g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
	v_TexCoordRipple *= g_Scale;

	float rippleTextureAdjustment = (g_Texture0Resolution.x / g_Texture0Resolution.y);
	v_TexCoordRipple.xz *= rippleTextureAdjustment;
	v_TexCoordRipple.yw *= g_Ratio;
#else
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	v_TexCoordPerspective = mul(vec3(a_TexCoord.xy, 1.0), xform);
#endif
	
#if MASK == 1
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
