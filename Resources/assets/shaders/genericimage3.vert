
#include "common_vertex.h"

uniform mat4 g_ModelMatrix;
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Rotation;
uniform vec2 g_Texture0Translation;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];
#endif

#if MORPHING
attribute vec4 a_PositionVec4;
#else
attribute vec3 a_Position;
#endif
attribute vec2 a_TexCoord;

#if VERTEXCOLOR
attribute vec4 a_Color;
varying vec4 v_Color;
#endif

#if SKINNING
attribute vec3 a_Normal;
#if NORMALMAP
attribute vec4 a_Tangent4;
#endif
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

#if PBRMASKS
uniform vec4 g_Texture2Resolution;
varying vec4 v_TexCoord;
#else
varying vec2 v_TexCoord;
#endif

uniform vec3 g_EyePosition;

#if LIGHTING || REFLECTION
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
#define M_MDL g_ModelMatrix
#endif

#if LIGHTING
uniform mat4 g_ViewProjectionMatrix;
#endif

#if LIGHTING || REFLECTION
varying vec4 v_ViewDir;
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
varying vec3 v_WorldPos;
#if NORMALMAP == 0
varying vec3 v_WorldNormal;
#endif
#elif FOG_COMPUTED && (FOG_DIST || FOG_HEIGHT)
varying vec4 v_ViewDir;
#endif

#if REFLECTION && NORMALMAP || BLENDMODE
varying vec3 v_ScreenPos;
#endif

#ifdef SKINNING_ALPHA
uniform float g_BonesAlpha[BONECOUNT];
#endif

#if MORPHING
uniform sampler2D g_Texture5; // {"hidden":true}
uniform vec4 g_Texture5Resolution;

uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];
#endif

#if MORPHING || SKINNING_ALPHA
varying float v_VertexAlpha;
#endif

void main() {
#if MORPHING
	vec3 position = a_PositionVec4.xyz;
#else
	vec3 position = a_Position.xyz;
#endif

#if MORPHING || SKINNING_ALPHA
	v_VertexAlpha = 1.0;
#endif

	vec3 localPos = position;
	
#if MORPHING
	vec2 texture5ResolutionInv = 1.0 / g_Texture5Resolution.xy;
	vec3 morphPos = CAST3(0.0);
	for (uint morphTarget = 0u; morphTarget < g_MorphOffsets[0] % 12u && a_PositionVec4.w > 0.0; ++morphTarget)
	{
		uint morphMapIndex = CASTU(a_PositionVec4.w) + g_MorphOffsets[1u + morphTarget];
		vec2 offset = 0.5 * texture5ResolutionInv;
		
		uint morphPixelx = morphMapIndex % CASTU(g_Texture5Resolution.x);
		uint morphPixely = morphMapIndex / CASTU(g_Texture5Resolution.y);
		
		vec4 morphCol = texSample2DLod(g_Texture5, vec2(morphPixelx, morphPixely) * texture5ResolutionInv + offset, 0.0);
		
		morphPos += morphCol.xyz * g_MorphWeights[1u + morphTarget];
#if PRELIGHTING == 0
		v_VertexAlpha *= morphCol.w * g_MorphWeights[1u + morphTarget] + 1.0 * (1.0 - g_MorphWeights[1u + morphTarget]);
#endif
	}
	
	localPos += morphPos * g_MorphWeights[0];
#endif

#if SKINNING
	localPos = mul(vec4(localPos, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
					g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
					g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
					g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
#endif

#if SKINNING_ALPHA
	v_VertexAlpha *= saturate(g_BonesAlpha[a_BlendIndices.x] * a_BlendWeights.x +
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

	vec4 worldPos = mul(vec4(localPos, 1.0), M_MDL);
	vec3 viewDir = g_EyePosition - worldPos.xyz;

#if LIGHTING || REFLECTION
	vec3 normal = vec3(0, 0, 1.0);

#if SKINNING
	normal = mul(a_Normal, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#endif

#if NORMALMAP
	vec4 tangent = vec4(1, 0, 0, 1);

#if SKINNING
	tangent.w = a_Tangent4.w;
	tangent.xyz = mul(a_Tangent4.xyz, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#endif
	mat3 tangentSpace = BuildTangentSpace(M_NML, normal, tangent);

	v_Tangent = normalize(tangentSpace[0]);
	v_Bitangent = normalize(tangentSpace[1]);
	v_Normal = normalize(tangentSpace[2]);
	v_WorldPos = worldPos.xyz;
#else

	v_WorldPos = worldPos.xyz;
#if SKINNING
	v_WorldNormal = mul(a_Normal, M_NML);
#else
	v_WorldNormal = mul(vec3(0, 0, 1), M_NML);
#endif

#endif
	v_ViewDir.xyz = viewDir;
	v_ViewDir.w = 0.0;
#endif

#if LIGHTING
	gl_Position = mul(worldPos, M_VP);
#else
	gl_Position = mul(vec4(localPos, 1.0), M_MVP);
#endif

#if REFLECTION && NORMALMAP || BLENDMODE
	v_ScreenPos = gl_Position.xyw;
#ifdef HLSL
	v_ScreenPos.y = -v_ScreenPos.y;
#endif
#endif

#if PRELIGHTING
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
#endif

#if VERTEXCOLOR
	v_Color = a_Color;
#endif

#if FOG_COMPUTED && (FOG_DIST || FOG_HEIGHT)
	v_ViewDir = vec4(viewDir, worldPos.y);
#endif
}
