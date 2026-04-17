
#include "common_vertex.h"

uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewProjectionMatrix;
uniform vec3 g_EyePosition;
uniform vec3 g_LightsPosition[4];
uniform vec3 g_LightAmbientColor;
uniform vec3 g_LightSkylightColor;

attribute vec3 a_Position;
attribute vec3 a_Normal;
#if LIGHTMAP
attribute vec4 a_TexCoordVec4;
#else
attribute vec2 a_TexCoord;
#endif

#if NORMALMAP
attribute vec4 a_Tangent4;
#else
varying vec3 v_Normal;
#endif

varying vec3 v_ViewDir;
#if LIGHTMAP
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif
varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;

#if REFLECTION
varying vec3 v_ScreenPos;
#endif

varying vec3 v_LightAmbientColor;

void main() {
	vec4 worldPos = mul(vec4(a_Position, 1.0), g_ModelMatrix);
	gl_Position = mul(worldPos, g_ViewProjectionMatrix);
	vec3 normal = normalize(mul(a_Normal, CAST3X3(g_ModelMatrix)));
#if LIGHTMAP
	v_TexCoord = a_TexCoordVec4;
#else
	v_TexCoord = a_TexCoord;
#endif
	
#if REFLECTION
	v_ScreenPos = gl_Position.xyw;
#endif
	
	v_ViewDir = g_EyePosition - worldPos.xyz;

	v_Light0DirectionL3X.xyz = g_LightsPosition[0] - worldPos.xyz;
	v_Light1DirectionL3Y.xyz = g_LightsPosition[1] - worldPos.xyz;
	v_Light2DirectionL3Z.xyz = g_LightsPosition[2] - worldPos.xyz;
	
	vec3 l3 = g_LightsPosition[3] - worldPos.xyz;
	
#if NORMALMAP
	mat3 tangentSpace = BuildTangentSpace(CAST3X3(g_ModelMatrix), a_Normal, a_Tangent4);
	v_Light0DirectionL3X.xyz = mul(tangentSpace, v_Light0DirectionL3X.xyz);
	v_Light1DirectionL3Y.xyz = mul(tangentSpace, v_Light1DirectionL3Y.xyz);
	v_Light2DirectionL3Z.xyz = mul(tangentSpace, v_Light2DirectionL3Z.xyz);
	l3 = mul(tangentSpace, l3);
	v_ViewDir = mul(tangentSpace, v_ViewDir);
#else
	v_Normal = normal;
#endif

	v_Light0DirectionL3X.w = l3.x;
	v_Light1DirectionL3Y.w = l3.y;
	v_Light2DirectionL3Z.w = l3.z;
	v_LightAmbientColor = mix(g_LightSkylightColor, g_LightAmbientColor, dot(normal, vec3(0, 1, 0)) * 0.5 + 0.5);
}
