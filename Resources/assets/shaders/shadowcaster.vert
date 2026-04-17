
// [COMBO] {"combo":"SKINNING"}
// [COMBO] {"combo":"MORPHING"}
// [COMBO] {"combo":"MORPHING_NORMALS"}
// [COMBO] {"combo":"BONECOUNT"}

uniform mat4 g_ModelMatrix;

uniform mat4 g_ViewportViewProjectionMatrices[6];
in uint gl_InstanceID;
varying uint gl_ViewportIndex;

attribute vec3 a_Position;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];

attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

#if MORPHING
#if HLSL
in uint gl_VertexID;
#endif

uniform sampler2D g_Texture1; // {"material":"morph"}
uniform vec4 g_Texture1Resolution;

uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];
#endif

#if ALPHATOCOVERAGE
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
#endif

void main() {
#if ALPHATOCOVERAGE
	v_TexCoord = a_TexCoord;
#endif

	vec3 localPos = a_Position;

#if MORPHING
	vec2 texture5ResolutionInv = 1.0 / g_Texture1Resolution.xy;
	vec3 morphPos = CAST3(0.0);
	for (uint morphTarget = 0u; morphTarget < g_MorphOffsets[0] % 12u; ++morphTarget)
	{
		uint morphMapOffset = gl_VertexID + g_MorphOffsets[1u + morphTarget];
		vec2 offset = 0.5 * texture5ResolutionInv;

#if MORPHING_NORMALS
		uint morphMapIndex = (morphMapOffset * 6u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 6u) % 4u);
		
		uint morphPixel1x = morphMapIndex % CASTU(g_Texture1Resolution.x);
		uint morphPixel1y = morphMapIndex / CASTU(g_Texture1Resolution.y);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(g_Texture1Resolution.x);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(g_Texture1Resolution.y);
		
		vec4 morphCol1 = texSample2DLod(g_Texture1, vec2(morphPixel1x, morphPixel1y) * texture5ResolutionInv + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(g_Texture1, vec2(morphPixel2x, morphPixel2y) * texture5ResolutionInv + offset, 0.0);
		
		vec3 posDeltaV1 = morphCol1.xyz;
		vec3 posDeltaV2 = vec3(morphCol1.zw, morphCol2.x);
		
		vec3 posDelta = mix(posDeltaV1, posDeltaV2, step(1.0, morphMapFlip));
		morphPos += posDelta.rgb * g_MorphWeights[1u + morphTarget];
#else
		uint morphMapIndex = (morphMapOffset * 3u) / 4u;
		float morphMapFlip = CASTF((morphMapOffset * 3u) % 4u);
		
		uint morphPixel1x = morphMapIndex % CASTU(g_Texture1Resolution.x);
		uint morphPixel1y = morphMapIndex / CASTU(g_Texture1Resolution.y);
		uint morphPixel2x = (morphMapIndex + 1u) % CASTU(g_Texture1Resolution.x);
		uint morphPixel2y = (morphMapIndex + 1u) / CASTU(g_Texture1Resolution.y);
		
		vec4 morphCol1 = texSample2DLod(g_Texture1, vec2(morphPixel1x, morphPixel1y) * texture5ResolutionInv + offset, 0.0);
		vec4 morphCol2 = texSample2DLod(g_Texture1, vec2(morphPixel2x, morphPixel2y) * texture5ResolutionInv + offset, 0.0);
		
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
#endif

#if SKINNING
	localPos = mul(vec4(localPos, 1.0), g_Bones[a_BlendIndices.x] * a_BlendWeights.x +
					g_Bones[a_BlendIndices.y] * a_BlendWeights.y +
					g_Bones[a_BlendIndices.z] * a_BlendWeights.z +
					g_Bones[a_BlendIndices.w] * a_BlendWeights.w);
#endif

	gl_Position = mul(mul(vec4(localPos, 1.0), g_ModelMatrix), g_ViewportViewProjectionMatrices[gl_InstanceID]);
	gl_ViewportIndex = gl_InstanceID;
}
