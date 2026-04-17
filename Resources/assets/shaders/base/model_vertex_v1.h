
#include "common_vertex.h"

uniform mat4 g_ModelMatrix;
uniform mat3 g_NormalModelMatrix;
uniform vec3 g_LightAmbientColor;
uniform vec3 g_LightSkylightColor;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];

attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

#if (LIGHTING || REFLECTION) && NORMALMAP
attribute vec4 a_Tangent4;
#endif

#if MORPHING
#if HLSL
in uint gl_VertexID;
#endif

uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];
#endif

#if MORPHING
void ApplyMorphPositionNormal(in uint vertexID, DECLARE_SAMPLER2D_PARAMETER(morphTexture), in vec4 morphTextureTexel, in uint morphOffsets[12], in float morphWeights[12], inout vec3 localPos, inout vec3 localNormal)
{
	vec3 morphPos = CAST3(0.0);
	vec3 morphNormal = CAST3(0.0);
	for (uint morphTarget = 0u; morphTarget < morphOffsets[0] % 12u; ++morphTarget)
	{
		uint morphMapOffset = vertexID + morphOffsets[1u + morphTarget];
		vec2 offset = 0.5 * morphTextureTexel.xy;

#if MORPHING_NORMALS
		uint morphMapIndex = (morphMapOffset * 6u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 6u) % 4u);

		uint morphPixel1x = morphMapIndex % CASTU(morphTextureTexel.z);
		uint morphPixel1y = morphMapIndex / CASTU(morphTextureTexel.w);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(morphTextureTexel.z);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(morphTextureTexel.w);
		
		vec4 morphCol1 = texSample2DLod(morphTexture, vec2(morphPixel1x, morphPixel1y) * morphTextureTexel.xy + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(morphTexture, vec2(morphPixel2x, morphPixel2y) * morphTextureTexel.xy + offset, 0.0);
		
		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.zw, morphCol2.x);
		
		vec3 posDelta = mix(posDeltaV1, posDeltaV2, step(1.0, morphMapFlip));
		morphPos += posDelta.rgb * morphWeights[1u + morphTarget];
		
		vec3 normalDeltaV1 = vec3(morphCol1.w, morphCol2.xy);
		vec3 normalDeltaV2 = morphCol2.yzw;
		
		vec3 normalDelta = mix(normalDeltaV1, normalDeltaV2, step(1.0, morphMapFlip));
		morphNormal += normalDelta * morphWeights[1u + morphTarget];
#else
		uint morphMapIndex = (morphMapOffset * 3u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 3u) % 4u);
		
		uint morphPixel1x = morphMapIndex % CASTU(morphTextureTexel.z);
		uint morphPixel1y = morphMapIndex / CASTU(morphTextureTexel.w);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(morphTextureTexel.z);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(morphTextureTexel.w);
		
		vec4 morphCol1 = texSample2DLod(morphTexture, vec2(morphPixel1x, morphPixel1y) * morphTextureTexel.xy + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(morphTexture, vec2(morphPixel2x, morphPixel2y) * morphTextureTexel.xy + offset, 0.0);
		
		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.w, morphCol2.xy);
		vec3 posDeltaV3 = vec3(morphCol1.zw, morphCol2.x);
		vec3 posDeltaV4 = morphCol1.yzw;
		
		vec3 posDelta = mix(posDeltaV1, mix(posDeltaV4, mix(posDeltaV3, posDeltaV2,
			step(2.5, morphMapFlip)), step(1.5, morphMapFlip)), step(0.5, morphMapFlip));
		morphPos += posDelta.rgb * morphWeights[1u + morphTarget];
#endif
	}

	localPos += morphPos * morphWeights[0];

#if MORPHING_NORMALS
	localNormal = normalize(localNormal + morphNormal * 3.465);
#endif
}

void ApplyMorphPosition(in uint vertexID, DECLARE_SAMPLER2D_PARAMETER(morphTexture), in vec4 morphTextureTexel, in uint morphOffsets[12], in float morphWeights[12], inout vec3 localPos)
{
	vec3 morphPos = CAST3(0.0);
	for (uint morphTarget = 0u; morphTarget < morphOffsets[0] % 12u; ++morphTarget)
	{
		uint morphMapOffset = vertexID + morphOffsets[1u + morphTarget];
		vec2 offset = 0.5 * morphTextureTexel.xy;

#if MORPHING_NORMALS
		uint morphMapIndex = (morphMapOffset * 6u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 6u) % 4u);

		uint morphPixel1x = morphMapIndex % CASTU(morphTextureTexel.z);
		uint morphPixel1y = morphMapIndex / CASTU(morphTextureTexel.w);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(morphTextureTexel.z);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(morphTextureTexel.w);
		
		vec4 morphCol1 = texSample2DLod(morphTexture, vec2(morphPixel1x, morphPixel1y) * morphTextureTexel.xy + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(morphTexture, vec2(morphPixel2x, morphPixel2y) * morphTextureTexel.xy + offset, 0.0);
		
		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.zw, morphCol2.x);
		
		vec3 posDelta = mix(posDeltaV1, posDeltaV2, step(1.0, morphMapFlip));
		morphPos += posDelta.rgb * morphWeights[1u + morphTarget];
#else
		uint morphMapIndex = (morphMapOffset * 3u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 3u) % 4u);
		
		uint morphPixel1x = morphMapIndex % CASTU(morphTextureTexel.z);
		uint morphPixel1y = morphMapIndex / CASTU(morphTextureTexel.w);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(morphTextureTexel.z);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(morphTextureTexel.w);
		
		vec4 morphCol1 = texSample2DLod(morphTexture, vec2(morphPixel1x, morphPixel1y) * morphTextureTexel.xy + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(morphTexture, vec2(morphPixel2x, morphPixel2y) * morphTextureTexel.xy + offset, 0.0);
		
		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.w, morphCol2.xy);
		vec3 posDeltaV3 = vec3(morphCol1.zw, morphCol2.x);
		vec3 posDeltaV4 = morphCol1.yzw;
		
		vec3 posDelta = mix(posDeltaV1, mix(posDeltaV4, mix(posDeltaV3, posDeltaV2,
			step(2.5, morphMapFlip)), step(1.5, morphMapFlip)), step(0.5, morphMapFlip));
		morphPos += posDelta.rgb * morphWeights[1u + morphTarget];
#endif
	}

	localPos += morphPos * morphWeights[0];
}
#endif

void ApplySkinningPositionNormal(in vec3 position, in vec3 normal, in uvec4 blendIndices, in vec4 blendWeights, out vec4 worldPosition, out vec3 worldNormal)
{
#if SKINNING
	position.xyz = mul(vec4(position, 1.0), g_Bones[blendIndices.x] * blendWeights.x +
					g_Bones[blendIndices.y] * blendWeights.y +
					g_Bones[blendIndices.z] * blendWeights.z +
					g_Bones[blendIndices.w] * blendWeights.w);
#endif

	worldPosition = mul(vec4(position, 1.0), g_ModelMatrix);

#if SKINNING
	normal = mul(normal, CAST3X3(g_Bones[blendIndices.x]) * blendWeights.x +
					CAST3X3(g_Bones[blendIndices.y]) * blendWeights.y +
					CAST3X3(g_Bones[blendIndices.z]) * blendWeights.z +
					CAST3X3(g_Bones[blendIndices.w]) * blendWeights.w);
#endif

	worldNormal = mul(normal, g_NormalModelMatrix);
}

void ApplyPositionNormal(in vec3 position, in vec3 normal, out vec4 worldPosition, out vec3 worldNormal)
{
	worldPosition = mul(vec4(position, 1.0), g_ModelMatrix);
	worldNormal = mul(normal, g_NormalModelMatrix);
}

void ApplySkinningPosition(in vec3 position, in uvec4 blendIndices, in vec4 blendWeights, out vec4 worldPosition)
{
#if SKINNING
	position.xyz = mul(vec4(position, 1.0), g_Bones[blendIndices.x] * blendWeights.x +
					g_Bones[blendIndices.y] * blendWeights.y +
					g_Bones[blendIndices.z] * blendWeights.z +
					g_Bones[blendIndices.w] * blendWeights.w);
#endif

	worldPosition = mul(vec4(position, 1.0), g_ModelMatrix);
}

void ApplyPosition(in vec3 position, out vec4 worldPosition)
{
	worldPosition = mul(vec4(position, 1.0), g_ModelMatrix);
}

#if (LIGHTING || REFLECTION) && NORMALMAP
void ApplySkinningTangentSpace(in vec3 worldNormal, in vec4 modelTangent, in uvec4 blendIndices, in vec4 blendWeights, out mat3 tangentSpace)
{
#if SKINNING
	vec3 tangent = mul(modelTangent.xyz, CAST3X3(g_Bones[blendIndices.x]) * blendWeights.x +
					CAST3X3(g_Bones[blendIndices.y]) * blendWeights.y +
					CAST3X3(g_Bones[blendIndices.z]) * blendWeights.z +
					CAST3X3(g_Bones[blendIndices.w]) * blendWeights.w);
#else
	vec3 tangent = modelTangent.xyz;
#endif

	tangentSpace = BuildTangentSpace(g_NormalModelMatrix, worldNormal, vec4(tangent, modelTangent.w));
	tangentSpace[0] = normalize(tangentSpace[0]);
	tangentSpace[1] = normalize(tangentSpace[1]);
	tangentSpace[2] = normalize(tangentSpace[2]);
}

void ApplyTangentSpace(in vec3 worldNormal, in vec4 modelTangent, out mat3 tangentSpace)
{
	vec3 tangent = modelTangent.xyz;
	tangentSpace = BuildTangentSpace(g_NormalModelMatrix, worldNormal, vec4(tangent, modelTangent.w));
	tangentSpace[0] = normalize(tangentSpace[0]);
	tangentSpace[1] = normalize(tangentSpace[1]);
	tangentSpace[2] = normalize(tangentSpace[2]);
}
#endif

vec3 ApplyAmbientLighting(in vec3 normal)
{
	return mix(g_LightSkylightColor, g_LightAmbientColor, dot(normal, vec3(0, 1, 0)) * 0.5 + 0.5);
}

void ClipSpaceToScreenSpace(in vec4 clipSpacePosition, out vec3 screenSpacePosition)
{
	screenSpacePosition = clipSpacePosition.xyw;
#ifdef HLSL
	screenSpacePosition.y = -screenSpacePosition.y;
#endif
}
