
#include "common_particles.h"

#if GS_ENABLED
/////////////////////////
// Geometry shader
/////////////////////////
#if THICKFORMAT
attribute vec4 a_PositionVec4;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_TexCoordVec4C1;
attribute vec4 a_TexCoordVec4C2;
attribute vec4 a_TexCoordVec4C3;
attribute vec4 a_Color;

varying vec4 v_EndPoint;
varying vec4 v_Color2;
#else
attribute vec4 a_PositionVec4;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_TexCoordVec4C1;
attribute vec3 a_TexCoordVec3C2;
#if TRAILSCROLLALPHA
varying vec4 v_EndPoint;
varying vec4 v_Color2;
#else
varying vec3 v_EndPoint;
#endif

attribute vec4 a_Color;

#endif

varying vec4 v_Color;

varying vec3 v_CPStart;
varying vec3 v_CPEnd;
varying vec2 v_UVMinMax;

void main() {

#define in_ParticleSize (a_PositionVec4.w)
#define in_SegmentUVTimeOffset (g_RenderVar0.z)
#define in_SegmentMaxCount (g_RenderVar0.w)
#define in_ParticleTrailLength (a_TexCoordVec4.w)
#define in_ParticleTrailPosition (a_TexCoordVec4C1.w)
#define in_SplineCP0 (a_TexCoordVec4C1.xyz)
#define in_TrailVertexIndex (a_TexCoordVec4.w)
#define in_SegmentMaxCountUnscaled (g_RenderVar0.x)

	gl_Position = vec4(a_PositionVec4.xyz, in_ParticleSize);
	v_EndPoint.xyz = a_TexCoordVec4.xyz;

#if THICKFORMAT
#define in_SplineCP1 (a_TexCoordVec4C2.xyz)

	v_EndPoint.w = a_TexCoordVec4C2.w;
	v_Color2 = a_TexCoordVec4C3;
#else
#define in_SplineCP1 (a_TexCoordVec3C2.xyz)
#endif

	v_Color = a_Color;

	float segmentTimeOffsetInverse = 1.0 - in_SegmentUVTimeOffset;

#if TRAILSCROLLALPHA
	float usableLength = in_SegmentMaxCount;
	float usableLengthUnscaled = in_SegmentMaxCountUnscaled;

	float uvMinimum = 1.0 - in_ParticleTrailPosition / usableLength;
	float uvDelta = -1.0 / usableLength;
	if (in_TrailVertexIndex < 0.5)
	{
		uvMinimum += uvDelta * segmentTimeOffsetInverse;
		uvDelta = uvDelta * in_SegmentUVTimeOffset;
	}

	v_EndPoint.w = in_ParticleSize;
	v_Color2 = a_Color;

	float trailFadeIn = sin(saturate((in_TrailVertexIndex - segmentTimeOffsetInverse) / usableLengthUnscaled) * 3.141);
	float trailFadeOut = sin(saturate((in_TrailVertexIndex - segmentTimeOffsetInverse + 1) / usableLengthUnscaled) * 3.141);
#if TRAILFADEALPHA
	v_Color.a *= trailFadeIn;
	v_Color2.a *= trailFadeOut;
#endif
#if TRAILFADESIZE
	gl_Position.w *= trailFadeIn;
	v_EndPoint.w *= trailFadeOut;
#endif
#elif TRAILRENDERER
	float usableLength = in_ParticleTrailLength - 1;
	// Still spawning new elements, extend to physical end of trail
	if (in_ParticleTrailLength < in_SegmentMaxCount)
	{
		usableLength += in_SegmentUVTimeOffset;
	}

	float uvMinimum = (in_ParticleTrailPosition - segmentTimeOffsetInverse) / usableLength;
	float uvDelta = 1.0 / usableLength;

	// The first element is shorter based on the history timer and always starts and UV 0
	if (in_ParticleTrailPosition < 0.5)
	{
		uvMinimum = 0.0;
		uvDelta = in_SegmentUVTimeOffset / usableLength;
	}
#else
	float usableLength = in_ParticleTrailLength - 1;

	// New particles are at the end of the array
	float uvMinimum = 1.0 - in_ParticleTrailPosition / usableLength;
	float uvDelta = -1.0 / usableLength;
#endif

	v_UVMinMax.x = uvMinimum;
	v_UVMinMax.y = uvMinimum + uvDelta;

	v_CPStart = a_PositionVec4.xyz - in_SplineCP0;
	v_CPEnd = v_EndPoint.xyz - in_SplineCP1;

	vec3 dt = v_EndPoint.xyz - a_PositionVec4.xyz;
	v_CPStart = v_CPStart + dt;
	v_CPEnd = v_CPEnd - dt;
}

#else

/////////////////////////
// No geometry shader
/////////////////////////

attribute vec4 a_PositionVec4;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_TexCoordVec4C1;

#if THICKFORMAT
attribute vec4 a_TexCoordVec4C2;
attribute vec4 a_TexCoordVec4C3;
attribute vec2 a_TexCoordC4;
#else
attribute vec3 a_TexCoordVec3C2;
attribute vec2 a_TexCoordC3;
#endif

attribute vec4 a_Color;

varying vec4 v_Color;

#if FOG_DIST || FOG_HEIGHT || LIGHTING
uniform mat4 g_ModelMatrix;
varying vec4 v_ViewDir;
#endif

#if LIGHTING
varying vec3 v_WorldPos;
varying vec3 v_WorldRight;
#endif

#if REFRACT
varying vec3 v_ScreenCoord;
varying vec4 v_ScreenTangents;
#endif

varying vec2 v_TexCoord;

void main() {

#define in_SegmentUVTimeOffset (g_RenderVar0.z)
#define in_SegmentMaxCount (g_RenderVar0.w)
#define in_ParticleTrailLength (a_TexCoordVec4.w)
#define in_ParticleTrailPosition (a_TexCoordVec4C1.w)
#define in_TrailVertexIndex (a_TexCoordVec4.w)
#define in_SegmentMaxCountUnscaled (g_RenderVar0.x)

	// Prepare input layout
	vec3 startPosition = a_PositionVec4.xyz;
	vec3 endPosition = a_TexCoordVec4.xyz;
	vec3 CPStart = startPosition - a_TexCoordVec4C1.xyz;

	float sizeStart = a_PositionVec4.w;
	vec4 colorStart = a_Color;

#if THICKFORMAT
	vec3 CPEnd = endPosition - a_TexCoordVec4C2.xyz;
	float sizeEnd = a_TexCoordVec4C2.w;
	vec4 colorEnd = a_TexCoordVec4C3;
	vec2 uvs = a_TexCoordC4.xy;
#else
	vec3 CPEnd = endPosition - a_TexCoordVec3C2.xyz;
	float sizeEnd = sizeStart;
	vec4 colorEnd = a_Color;
	vec2 uvs = a_TexCoordC3.xy;
#endif

	vec3 eyeDirection = mul(g_OrientationForward, CAST3X3(g_ModelMatrixInverse));
	vec3 trailDelta = endPosition - startPosition;

	vec3 trailRightStart = cross(eyeDirection, trailDelta + CPStart);
	vec3 trailRightEnd = cross(eyeDirection, trailDelta - CPEnd);

#if TRAILSCROLLALPHA
	float usableLength = in_SegmentMaxCount;
	float usableLengthUnscaled = in_SegmentMaxCountUnscaled;

	float segmentTimeOffsetInverse = 1.0 - in_SegmentUVTimeOffset;
	float trailFadeIn = sin(saturate((in_TrailVertexIndex - segmentTimeOffsetInverse) / usableLengthUnscaled) * 3.141);
	float trailFadeOut = sin(saturate((in_TrailVertexIndex - segmentTimeOffsetInverse + 1) / usableLengthUnscaled) * 3.141);
#if TRAILFADEALPHA
	colorStart.a *= trailFadeIn;
	colorEnd.a *= trailFadeOut;
#endif
#if TRAILFADESIZE
	sizeStart.w *= trailFadeIn;
	sizeEnd.w *= trailFadeOut;
#endif

	float uvMinimum = 1.0 - in_ParticleTrailPosition / usableLength;
	float uvDelta = -1.0 / usableLength;
	if (in_TrailVertexIndex < 0.5)
	{
		uvMinimum += uvDelta * segmentTimeOffsetInverse;
		uvDelta = uvDelta * in_SegmentUVTimeOffset;
	}
#elif TRAILRENDERER
	float usableLength = in_ParticleTrailLength - 1;
	// Still spawning new elements, extend to physical end of trail
	if (in_ParticleTrailLength < in_SegmentMaxCount)
	{
		usableLength += in_SegmentUVTimeOffset;
	}
	
	float uvMinimum = (in_ParticleTrailPosition - (1.0 - in_SegmentUVTimeOffset)) / usableLength;
	float uvDelta = 1.0 / usableLength;
	
	// The first element is shorter based on the history timer and always starts and UV 0
	if (in_ParticleTrailPosition < 0.5)
	{
		uvMinimum = 0.0;
		uvDelta = in_SegmentUVTimeOffset / usableLength;
	}
#else
	float usableLength = in_ParticleTrailLength - 1;
	float uvMinimum = 1.0 - in_ParticleTrailPosition / usableLength;
	float uvDelta = -1.0 / usableLength;
#endif

	vec4 color = mix(colorStart, colorEnd, uvs.y);

	trailRightStart = normalize(trailRightStart) * sizeStart;
	trailRightEnd = normalize(trailRightEnd) * sizeEnd;

	vec3 position = mix(startPosition, endPosition, uvs.y);
	vec3 right = mix(trailRightStart, trailRightEnd, uvs.y);
	position += right * uvs.x * 2.0 - 1.0;

	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);

	v_TexCoord.xy = uvs.xy;
	v_TexCoord.y = mix(uvMinimum, uvMinimum + uvDelta, uvs.y);

#if FOG_DIST || FOG_HEIGHT || LIGHTING
	vec3 worldPos = mul(vec4(position, 1.0), g_ModelMatrix).xyz;
	v_ViewDir.xyz = g_EyePosition - worldPos.xyz;
	v_ViewDir.w = worldPos.y;
#endif

#if LIGHTING
	v_WorldPos = worldPos;
	v_WorldRight = right;
#endif

	v_Color = color;

#if REFRACT
	vec3 up = cross(right, eyeDirection);
	ComputeScreenRefractionTangents(gl_Position.xyw, right, up, v_ScreenCoord, v_ScreenTangents);
#endif
}

#endif
