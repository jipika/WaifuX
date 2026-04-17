
// [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}

#include "common_perspective.h"

uniform mat4 g_EffectTextureProjectionMatrixInverse;
uniform vec2 g_PointerPosition;
uniform vec2 g_PointerPositionLast;
uniform vec4 g_Texture0Resolution;

uniform float g_RippleScale; // {"material":"ripplescale","label":"ui_editor_properties_ripple_scale","default":1.0,"range":[0,2]}


attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec4 v_PointerUV;
varying vec4 v_PointerUVLast;
varying vec2 v_PointDelta;

#if PERSPECTIVE == 1
uniform vec2 g_Point0; // {"hidden":true,"material":"point0","label":"p0","default":"0 0"}
uniform vec2 g_Point1; // {"hidden":true,"material":"point1","label":"p1","default":"1 0"}
uniform vec2 g_Point2; // {"hidden":true,"material":"point2","label":"p2","default":"1 1"}
uniform vec2 g_Point3; // {"hidden":true,"material":"point3","label":"p3","default":"0 1"}
//varying mat3 v_XForm;
#endif

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	v_TexCoord.xy = a_TexCoord.xy;
	
	vec2 pointer = g_PointerPosition;
	pointer.y = 1.0 - pointer.y; // Flip pointer screen space Y to match texture space Y
	vec2 pointerLast = g_PointerPositionLast;
	pointerLast.y = 1.0 - pointerLast.y;
	
#if PERSPECTIVE == 1
	mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
	//v_XForm = xform;
#endif

	vec4 preTransformPoint = vec4(pointer * 2 - 1, 0.0, 1.0);
	vec4 preTransformPointLast = vec4(pointerLast * 2 - 1, 0.0, 1.0);
	

	v_PointerUV.xyz = mul(preTransformPoint, g_EffectTextureProjectionMatrixInverse).xyw;
	v_PointerUV.xy *= 0.5;
	v_PointerUV.xy /= v_PointerUV.z;
	
	v_PointerUVLast.xyz = mul(preTransformPointLast, g_EffectTextureProjectionMatrixInverse).xyw;
	v_PointerUVLast.xy *= 0.5;
	v_PointerUVLast.xy /= v_PointerUVLast.z;


	v_PointerUV.w = g_Texture0Resolution.y / -g_Texture0Resolution.x;
	//v_PointerUV.y *= v_PointerUV.w;
	
	v_PointDelta.x = length(g_PointerPosition - g_PointerPositionLast);
	//v_PointDelta *= v_PointDelta;
	v_PointDelta.x *= 100;
	//v_PointDelta = 1;
	
	v_PointDelta.y = 60.0 / max(0.0001, g_RippleScale);
	v_PointerUV.w *= -v_PointDelta.y;
	v_PointerUVLast.w = v_PointerUV.w;
	
	v_PointerUV.z = 1.0;
	v_PointerUV.xy += 0.5;
	v_PointerUV.y = 1.0 - v_PointerUV.y;
	
	v_PointerUVLast.z = 1.0;
	v_PointerUVLast.xy += 0.5;
	v_PointerUVLast.y = 1.0 - v_PointerUVLast.y;
	
#if PERSPECTIVE == 1
	v_PointerUV.xyz = mul(v_PointerUV.xyz, xform);
	v_PointerUV.xy /= v_PointerUV.z;
	
	v_PointerUVLast.xyz = mul(v_PointerUVLast.xyz, xform);
	v_PointerUVLast.xy /= v_PointerUVLast.z;
#endif
	//vec2 pointerLast = g_PointerPositionLast;
	//pointerLast.y = 1.0 - pointerLast.y; // Flip pointer screen space Y to match texture space Y
	//v_PointerUVLast.xyz = mul(vec4(pointerLast * 2 - 1, 0.0, 1.0), g_EffectTextureProjectionMatrixInverse).xyw;
	//v_PointerUVLast.xy *= 0.5;
	//v_PointerUVLast.w = g_Texture0Resolution.y / -g_Texture0Resolution.x;
}
