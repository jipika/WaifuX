
#include "common_vertex.h"

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

#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

varying vec2 v_TexCoord;

#ifdef SKINNING_ALPHA
uniform float g_BonesAlpha[BONECOUNT];
#endif

#if MORPHING
uniform sampler2D g_Texture5; // {"hidden":true}
uniform vec4 g_Texture5Resolution;

uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];

#if MORPHING_MODIFIERS
uniform mat4x3 g_MorphBoneTransform[11];
uniform vec3 g_MorphBoneRules[11];
#endif
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

		float morphAmount = 1.0;
#if MORPHING_MODIFIERS
		vec3 preMorphPos = mul(vec4(localPos, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
						g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
						g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
						g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
		vec3 modifierInverseDelta = mul(vec4(preMorphPos, 1.0), g_MorphBoneTransform[morphTarget]);
		float boneDistance = length(modifierInverseDelta.xy);
		float bonePointRule = smoothstep(g_MorphBoneRules[morphTarget].y, g_MorphBoneRules[morphTarget].z, boneDistance);
		float boneAxisRule = smoothstep(g_MorphBoneRules[morphTarget].y, g_MorphBoneRules[morphTarget].z, modifierInverseDelta.x);
		morphAmount = mix(bonePointRule, boneAxisRule, g_MorphBoneRules[morphTarget].x);
#endif

		float morphWeight = morphAmount * g_MorphWeights[1u + morphTarget];
		morphPos += morphCol.xyz * morphWeight;
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

	gl_Position = mul(vec4(localPos, 1.0), g_ModelViewProjectionMatrix);
}
