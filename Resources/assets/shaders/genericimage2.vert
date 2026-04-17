
// [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":0}
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","default":0}

#include "common_vertex.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Rotation;
uniform vec2 g_Texture0Translation;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

#if PBRMASKS
uniform vec4 g_Texture2Resolution;
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif

#if LIGHTING || REFLECTION
uniform vec3 g_EyePosition;

uniform mat4 g_ModelMatrix;
uniform mat3 g_NormalModelMatrix;

uniform mat4 g_AltModelMatrix;
uniform mat3 g_AltNormalModelMatrix;
uniform mat4 g_AltViewProjectionMatrix;

#if PRELIGHTING
#define M_MDL g_AltModelMatrix
#define M_NML g_AltNormalModelMatrix
#define M_VP g_AltViewProjectionMatrix
#define M_MVP mul(g_AltModelMatrix, g_AltViewProjectionMatrix)
#else
#define M_MDL g_ModelMatrix
#define M_NML g_NormalModelMatrix
#define M_VP g_ViewProjectionMatrix
#define M_MVP g_ModelViewProjectionMatrix
#endif
#else
#define M_MVP g_ModelViewProjectionMatrix
#endif

#if LIGHTING
uniform mat4 g_ViewProjectionMatrix;
uniform vec3 g_LightsPosition[4];

varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;
#endif

#if (LIGHTING || REFLECTION) && NORMALMAP == 0
varying vec3 v_Normal;
#endif

#if REFLECTION && NORMALMAP
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
varying vec3 v_ScreenPos;
#endif

#if BLENDMODE
varying vec3 v_ScreenCoord;
#endif

#ifdef SKINNING_ALPHA
uniform float g_BonesAlpha[BONECOUNT];
varying float v_BoneAlpha;
#endif

void main() {

#if SKINNING
	vec3 localPos = mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
					g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
					g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
					g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
#else
	vec3 localPos = a_Position;
#endif

#if SKINNING_ALPHA
	v_BoneAlpha = saturate(g_BonesAlpha[a_BlendIndices.x] * a_BlendWeights.x +
					g_BonesAlpha[a_BlendIndices.y] * a_BlendWeights.y +
					g_BonesAlpha[a_BlendIndices.z] * a_BlendWeights.z +
					g_BonesAlpha[a_BlendIndices.w] * a_BlendWeights.w);
#endif

#if SPRITESHEET
	v_TexCoord.xy = g_Texture0Translation + a_TexCoord.x * g_Texture0Rotation.xy + a_TexCoord.y * g_Texture0Rotation.zw;
#else
	v_TexCoord.xy = a_TexCoord;
#endif

#if PBRMASKS
	v_TexCoord.zw = vec2(a_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						a_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif

#if LIGHTING || REFLECTION
	// Compute normal and tangent space for lighting and/or reflection later
	vec3 normal = vec3(0, 0, 1.0);
	vec3 tangent = vec3(1.0, 0, 0);
	vec4 worldPos = mul(vec4(localPos, 1.0), M_MDL);

#if SKINNING
	normal = mul(normal, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#endif

#if NORMALMAP

#if SKINNING
	tangent = mul(tangent, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#endif
	mat3 tangentSpace = BuildTangentSpace(M_NML, normal, vec4(tangent, 1.0));
#if REFLECTION
	v_Tangent = tangentSpace[0];
	v_Bitangent = tangentSpace[1];
#endif
#endif
#endif

	// Prepare lighting data
#if LIGHTING
	v_Light0DirectionL3X.xyz = g_LightsPosition[0] - worldPos.xyz;
	v_Light1DirectionL3Y.xyz = g_LightsPosition[1] - worldPos.xyz;
	v_Light2DirectionL3Z.xyz = g_LightsPosition[2] - worldPos.xyz;
	vec3 l3 = g_LightsPosition[3] - worldPos.xyz;

	gl_Position = mul(worldPos, M_VP);

#if NORMALMAP
	v_Light0DirectionL3X.xyz = mul(tangentSpace, v_Light0DirectionL3X.xyz);
	v_Light1DirectionL3Y.xyz = mul(tangentSpace, v_Light1DirectionL3Y.xyz);
	v_Light2DirectionL3Z.xyz = mul(tangentSpace, v_Light2DirectionL3Z.xyz);
	l3 = mul(tangentSpace, l3);
#else
	v_Normal = normalize(mul(normal, M_NML));
#endif

	v_Light0DirectionL3X.w = l3.x;
	v_Light1DirectionL3Y.w = l3.y;
	v_Light2DirectionL3Z.w = l3.z;

#else
	gl_Position = mul(vec4(localPos, 1.0), M_MVP);
#endif

#if REFLECTION && NORMALMAP
	v_ScreenPos = gl_Position.xyw;
#ifdef HLSL
	v_ScreenPos.y = -v_ScreenPos.y;
	v_Tangent.y = -v_Tangent.y;
	v_Bitangent.y = -v_Bitangent.y;
#endif
#endif

#if PRELIGHTING
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
#endif

#if BLENDMODE
	v_ScreenCoord = gl_Position.xyw;
#ifdef HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif
#endif
}
