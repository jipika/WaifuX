
#if FOG_DIST
uniform vec3 g_FogDistanceColor;
uniform vec4 g_FogDistanceParams;
#endif

#if FOG_HEIGHT
uniform vec3 g_FogHeightColor;
uniform vec4 g_FogHeightParams;
#endif

vec2 CalculateFogPixelState(float viewDirLength, float worldPosHeight)
{
	vec2 result = CAST2(0);
#if FOG_DIST
	result.x = (viewDirLength - g_FogDistanceParams.x) / g_FogDistanceParams.y;
#endif
#if FOG_HEIGHT
	result.y = (worldPosHeight - g_FogHeightParams.x) / g_FogHeightParams.y;
#endif
	return result;
}

vec3 ApplyFog(in vec3 color, in vec2 fogPixelState)
{
#if FOG_HEIGHT
	float fogHeight = saturate(fogPixelState.y);
	color.rgb = mix(color.rgb, g_FogHeightColor,
		g_FogHeightParams.z + g_FogHeightParams.w * fogHeight * fogHeight);
#endif
#if FOG_DIST
	float fogDistance = saturate(fogPixelState.x);
	color.rgb = mix(color.rgb, g_FogDistanceColor,
		g_FogDistanceParams.z + g_FogDistanceParams.w * fogDistance * fogDistance);
#endif
	return color;
}

float ApplyFogAlpha(in float alpha, in vec2 fogPixelState)
{
#if FOG_DIST
	float fogDistance = saturate(fogPixelState.x);
	fogDistance = g_FogDistanceParams.z + g_FogDistanceParams.w * fogDistance * fogDistance;
#else
	float fogDistance = 0.0;
#endif
#if FOG_HEIGHT
	float fogHeight = saturate(fogPixelState.y);
	fogHeight = g_FogHeightParams.z + g_FogHeightParams.w * fogHeight * fogHeight;
#else
	float fogHeight = 0.0;
#endif
	float fogFactor = saturate(max(fogDistance, fogHeight));
	return alpha * (1.0 - (fogFactor * fogFactor));
}
