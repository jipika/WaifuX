
float CalcLeavesUVWeight(vec2 uvs, vec2 uvBounds)
{
#if LEAVESUVMODE == 1
	return saturate((1.0 - uvs.y - uvBounds.x) * uvBounds.y);
#elif LEAVESUVMODE == 2
	return saturate((uvs.y - uvBounds.x) * uvBounds.y);
#elif LEAVESUVMODE == 3
	return saturate((uvs.x - uvBounds.x) * uvBounds.y);
#elif LEAVESUVMODE == 4
	return saturate((1.0 - uvs.x - uvBounds.x) * uvBounds.y);
#endif
	return 1.0;
}

vec3 CalcFoliageAnimation(vec3 worldPos, vec3 localPos, vec2 uvs, float direction, float time, float speedLeaves, float speedBase, float strengthLeaves, float strengthBase, float phase, float scale, float cutoff, float treeHeight, float treeRadius, vec2 uvBounds)
{
	vec3 foliageOffsetForward = vec3(cos(direction), 0, sin(direction));
	vec3 foliageOffsetUp = vec3(0, 1, 0);

	vec4 fastSines = sin(phase + speedLeaves * time * vec4(1.71717171, -1.56161616, -1.9333, 1.041666666) + worldPos.xzzy * scale * 3.333);
	vec4 slowSines = sin(phase + speedBase * time * vec4(0.53333, -0.019841, -0.13888889, 0.0024801587) + worldPos.xyyx * scale);
	fastSines = smoothstep(CAST4(cutoff) + fastSines * 0.1, CAST4(1.0 - cutoff) - fastSines.zwyx * 0.1, fastSines * CAST4(0.5) + CAST4(0.5)) * CAST4(2.0) - CAST4(1.0);
	float cutoffBase = cutoff * 0.6666;
	slowSines = smoothstep(CAST4(cutoffBase) + slowSines * 0.1, CAST4(1.0 - cutoffBase) - slowSines.zwyx * 0.1, slowSines * CAST4(0.5) + CAST4(0.5)) * CAST4(2.0) - CAST4(1.0);

	float leafMask = strengthLeaves * smoothstep(-1.2, -0.3, sin(dot(worldPos.xyz, foliageOffsetForward) + speedBase * time));
	float leafDistance = dot(localPos.xz, localPos.xz);
	float baseMask = smoothstep(0.0, treeHeight, localPos.y);

	vec2 blendParamsA = vec2(treeRadius * treeRadius, treeRadius);
	vec2 blendParamsB = vec2(treeRadius, treeRadius * treeRadius);
	vec2 blendParams = mix(blendParamsA, blendParamsB, step(1.0, treeRadius));
	leafMask *= mix(smoothstep(blendParams.x, blendParams.y, leafDistance), baseMask, baseMask) * CalcLeavesUVWeight(uvs, uvBounds);
	baseMask *= strengthBase;

	vec4 strengthMask = vec4(leafMask, leafMask, baseMask, baseMask);
	return dot(strengthMask, vec4(fastSines.xy, slowSines.xy)) * foliageOffsetForward +
		dot(strengthMask, vec4(fastSines.zw, slowSines.zw)) * foliageOffsetUp;
}
