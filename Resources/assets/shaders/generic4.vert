
#include "common_vertex.h"

uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewProjectionMatrix;
uniform vec3 g_EyePosition;
uniform vec3 g_LightAmbientColor;
uniform vec3 g_LightSkylightColor;

attribute vec3 a_Position;
attribute vec3 a_Normal;
attribute vec2 a_TexCoord;
//attribute vec4 a_Color4u;
//varying vec4 v_VertexColor;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];

attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

varying vec4 v_ViewDir;
varying vec2 v_TexCoord;
varying vec3 v_LightAmbientColor;

#if LIGHTING || REFLECTION
#if NORMALMAP
attribute vec4 a_Tangent4;
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
#else
varying vec3 v_WorldNormal;
#endif
varying vec3 v_WorldPos;
#endif

#if REFLECTION
varying vec3 v_ScreenPos;
#endif

#if MORPHING
#if HLSL
in uint gl_VertexID;
#endif

uniform sampler2D g_Texture5; // {"material":"morph","hidden":true}
uniform vec4 g_Texture5Resolution;

uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];
#endif

void main() {
	vec3 localPos = a_Position;
	vec3 localNormal = a_Normal;

#if MORPHING
	vec2 texture5ResolutionInv = 1.0 / g_Texture5Resolution.xy;
	vec3 morphPos = CAST3(0.0);
	vec3 morphNormal = CAST3(0.0);
	for (uint morphTarget = 0u; morphTarget < g_MorphOffsets[0] % 12u; ++morphTarget)
	{
		uint morphMapOffset = CASTU(gl_VertexID) + g_MorphOffsets[1u + morphTarget];
		vec2 offset = 0.5 * texture5ResolutionInv;

#if MORPHING_NORMALS
		uint morphMapIndex = (morphMapOffset * 6u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 6u) % 4u);

		uint morphPixel1x = morphMapIndex % CASTU(g_Texture5Resolution.x);
		uint morphPixel1y = morphMapIndex / CASTU(g_Texture5Resolution.y);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(g_Texture5Resolution.x);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(g_Texture5Resolution.y);

		vec4 morphCol1 = texSample2DLod(g_Texture5, vec2(morphPixel1x, morphPixel1y) * texture5ResolutionInv + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(g_Texture5, vec2(morphPixel2x, morphPixel2y) * texture5ResolutionInv + offset, 0.0);

		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.zw, morphCol2.x);

		vec3 posDelta = mix(posDeltaV1, posDeltaV2, step(1.0, morphMapFlip));
		morphPos += posDelta.rgb * g_MorphWeights[1u + morphTarget];

		vec3 normalDeltaV1 = vec3(morphCol1.w, morphCol2.xy);
		vec3 normalDeltaV2 = morphCol2.yzw;

		vec3 normalDelta = mix(normalDeltaV1, normalDeltaV2, step(1.0, morphMapFlip));
		morphNormal += normalDelta * g_MorphWeights[1u + morphTarget];
#else
		uint morphMapIndex = (morphMapOffset * 3u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 3u) % 4u);

		uint morphPixel1x = morphMapIndex % CASTU(g_Texture5Resolution.x);
		uint morphPixel1y = morphMapIndex / CASTU(g_Texture5Resolution.y);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(g_Texture5Resolution.x);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(g_Texture5Resolution.y);

		vec4 morphCol1 = texSample2DLod(g_Texture5, vec2(morphPixel1x, morphPixel1y) * texture5ResolutionInv + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(g_Texture5, vec2(morphPixel2x, morphPixel2y) * texture5ResolutionInv + offset, 0.0);

		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.w, morphCol2.xy);
		vec3 posDeltaV3 = vec3(morphCol1.zw, morphCol2.x);
		vec3 posDeltaV4 = morphCol1.yzw;

		vec3 posDelta = mix(posDeltaV1, mix(posDeltaV4, mix(posDeltaV3, posDeltaV2,
			step(2.5, morphMapFlip)), step(1.5, morphMapFlip)), step(0.5, morphMapFlip));
		morphPos += posDelta.rgb * g_MorphWeights[1u + morphTarget];
#endif
	}

	localPos += morphPos * g_MorphWeights[0];

#if MORPHING_NORMALS
	localNormal = normalize(localNormal + morphNormal * 3.465);
#endif
#endif

#if SKINNING
	localPos = mul(vec4(localPos, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
					g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
					g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
					g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
#endif

	vec4 worldPos = mul(vec4(localPos, 1.0), g_ModelMatrix);
	gl_Position = mul(worldPos, g_ViewProjectionMatrix);

#if SKINNING
	localNormal = mul(localNormal, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#endif

	vec3 normal = normalize(mul(localNormal, CAST3X3(g_ModelMatrix)));

	v_TexCoord.xy = a_TexCoord;
	v_ViewDir.xyz = g_EyePosition - worldPos.xyz;
	v_ViewDir.w = worldPos.y;

#if LIGHTING || REFLECTION
	v_WorldPos = worldPos.xyz;
#if NORMALMAP
#if SKINNING
	vec3 tangent = mul(a_Tangent4.xyz, CAST3X3(g_Bones[a_BlendIndices.x]) * a_BlendWeights.x +
					CAST3X3(g_Bones[a_BlendIndices.y]) * a_BlendWeights.y +
					CAST3X3(g_Bones[a_BlendIndices.z]) * a_BlendWeights.z +
					CAST3X3(g_Bones[a_BlendIndices.w]) * a_BlendWeights.w);
#else
	vec3 tangent = a_Tangent4.xyz;
#endif

	mat3 tangentSpace = BuildTangentSpace(CAST3X3(g_ModelMatrix), localNormal, vec4(tangent, a_Tangent4.w));

	v_Tangent = normalize(tangentSpace[0]);
	v_Bitangent = normalize(tangentSpace[1]);
	v_Normal = normalize(tangentSpace[2]);
#else
	v_WorldNormal = normal;
#endif
#endif

#if REFLECTION
	v_ScreenPos = gl_Position.xyw;
#ifdef HLSL
	v_ScreenPos.y = -v_ScreenPos.y;
#endif
#endif

	//v_VertexColor = a_Color4u;
	v_LightAmbientColor = mix(g_LightSkylightColor, g_LightAmbientColor, dot(normal, vec3(0, 1, 0)) * 0.5 + 0.5);
}
