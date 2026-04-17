
#include "common_particles.h"

#ifndef TRAILSUBDIVISION
#define TRAILSUBDIVISION 0
#endif

#if THICKFORMAT || TRAILSCROLLALPHA
in vec4 v_EndPoint;
in vec4 v_Color2;
#else
in vec3 v_EndPoint;
#endif

in vec4 v_Color;
in vec4 gl_Position;
in vec2 v_UVMinMax;

in vec3 v_CPStart;
in vec3 v_CPEnd;

#if FOG_DIST || FOG_HEIGHT || LIGHTING || REFRACT
uniform mat4 g_ModelMatrix;
#endif

#if FOG_DIST || FOG_HEIGHT || LIGHTING
out vec4 v_ViewDir;
#endif

#if LIGHTING
out vec3 v_WorldPos;
out vec3 v_WorldRight;
#endif

#if REFRACT
out vec3 v_ScreenCoord;
out vec4 v_ScreenTangents;
#endif

out vec2 v_TexCoord;
out vec4 v_Color;
out vec4 gl_Position;

vec3 cubicBezier(vec3 A, vec3 B, vec3 C, vec3 D, float t)
{
	vec3 p;
	float OneMinusT = 1.0 - t;
	float b0 = OneMinusT*OneMinusT*OneMinusT;
	float b1 = 3.0*t*OneMinusT*OneMinusT;
	float b2 = 3.0*t*t*OneMinusT;
	float b3 = t*t*t;
	return b0*A + b1*B + b2*C + b3*D;
}

[maxvertexcount(4 + TRAILSUBDIVISION * 2)]
void main() {
	vec3 startPosition = IN[0].gl_Position.xyz;
	vec3 endPosition = IN[0].v_EndPoint.xyz;
	vec3 CPStart = IN[0].v_CPStart.xyz;
	vec3 CPEnd = IN[0].v_CPEnd.xyz;

#if THICKFORMAT || TRAILSCROLLALPHA
	float sizeStart = IN[0].gl_Position.w;
	float sizeEnd = IN[0].v_EndPoint.w;
#else
	float sizeStart = IN[0].gl_Position.w;
	float sizeEnd = IN[0].gl_Position.w;
#endif

#if ORIENTATION == 0
	vec3 eyeModel = mul(vec4(g_EyePosition, 1.0), g_ModelMatrixInverse);
	vec3 eyeDirection = normalize(((endPosition + startPosition) * 0.5) - eyeModel);
#else
	vec3 eyeDirection = mul(g_OrientationForward, CAST3X3(g_ModelMatrixInverse));
#endif

	vec3 trailDelta = endPosition - startPosition;

	vec3 trailRightStart = cross(eyeDirection, CPStart);
	trailRightStart = normalize(trailRightStart) * sizeStart;

	vec3 trailRightEnd = cross(eyeDirection, trailDelta - (CPEnd + trailDelta));
	trailRightEnd = normalize(trailRightEnd) * sizeEnd;

	float uvMinmimum = IN[0].v_UVMinMax.x;
	float uvMaximum = IN[0].v_UVMinMax.y;

	CPStart = startPosition + CPStart * 0.15;
	CPEnd = endPosition + CPEnd * 0.15;

	PS_INPUT v;

#if REFRACT || LIGHTING
	vec3 right;
#endif

#if FOG_DIST || FOG_HEIGHT || LIGHTING
	vec3 worldPos = mul(vec4(startPosition, 1.0), g_ModelMatrix).xyz;
	v.v_ViewDir.xyz = g_EyePosition - worldPos.xyz;
	v.v_ViewDir.w = worldPos.y;
#endif

#if THICKFORMAT || TRAILSCROLLALPHA
	// Update color per set
	vec4 colorStart = IN[0].v_Color;
	vec4 colorEnd = IN[0].v_Color2;

	v.v_Color = colorStart;
	v.gl_Position = mul(vec4(startPosition - trailRightStart, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(0, uvMinmimum);
#if REFRACT || LIGHTING
	right = mul(trailRightStart, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
	v.v_WorldPos = mul(vec4(startPosition - trailRightStart, 1.0), g_ModelMatrix);
	v.v_WorldRight = right;
#endif
#if REFRACT
	ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
	OUT.Append(v);
	v.gl_Position = mul(vec4(startPosition + trailRightStart, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(1, uvMinmimum);
#if LIGHTING
	v.v_WorldPos = mul(vec4(startPosition + trailRightStart, 1.0), g_ModelMatrix);
#endif
#if REFRACT
	ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
	OUT.Append(v);

#if TRAILSUBDIVISION != 0
	float subDivStep = 1.0 / (TRAILSUBDIVISION + 1);
	float subDivCounter = subDivStep;
	for (int s = 0; s < TRAILSUBDIVISION; ++s)
	{
		float s = smoothstep(0, 1, subDivCounter);
		vec3 midPosition = cubicBezier(startPosition, CPStart, CPEnd, endPosition, s);
		float midUV = mix(uvMinmimum, uvMaximum, s);
		vec3 midRight = mix(trailRightStart, trailRightEnd, s);
		vec4 color = mix(colorStart, colorEnd, s);

		v.v_Color = color;

		v.gl_Position = mul(vec4(midPosition - midRight, 1.0), g_ModelViewProjectionMatrix);
		v.v_TexCoord.xy = vec2(0, midUV);
#if REFRACT || LIGHTING
		right = mul(midRight, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
		v.v_WorldPos = mul(vec4(midPosition - midRight, 1.0), g_ModelMatrix);
		v.v_WorldRight = right;
#endif
#if REFRACT
		ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
		OUT.Append(v);
		v.gl_Position = mul(vec4(midPosition + midRight, 1.0), g_ModelViewProjectionMatrix);
		v.v_TexCoord.xy = vec2(1, midUV);
#if LIGHTING
		v.v_WorldPos = mul(vec4(midPosition + midRight, 1.0), g_ModelMatrix);
#endif
#if REFRACT
		ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
		OUT.Append(v);

		subDivCounter += subDivStep;
	}
#endif
	v.v_Color = colorEnd;
	v.gl_Position = mul(vec4(endPosition - trailRightEnd, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(0, uvMaximum);
#if REFRACT || LIGHTING
	right = mul(trailRightEnd, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
	v.v_WorldPos = mul(vec4(endPosition - trailRightEnd, 1.0), g_ModelMatrix);
	v.v_WorldRight = right;
#endif
#if REFRACT
	ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
	OUT.Append(v);
	v.gl_Position = mul(vec4(endPosition + trailRightEnd, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(1, uvMaximum);
#if LIGHTING
	v.v_WorldPos = mul(vec4(endPosition + trailRightEnd, 1.0), g_ModelMatrix);
#endif
#if REFRACT
	ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
	OUT.Append(v);


#else // NOT THICKFORMAT


	// Just set color once
	v.v_Color = IN[0].v_Color;
	v.gl_Position = mul(vec4(startPosition - trailRightStart, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(0, uvMinmimum);
#if REFRACT || LIGHTING
	right = mul(trailRightStart, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
	v.v_WorldPos = mul(vec4(startPosition - trailRightStart, 1.0), g_ModelMatrix);
	v.v_WorldRight = right;
#endif
#if REFRACT
	ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
	OUT.Append(v);
	v.gl_Position = mul(vec4(startPosition + trailRightStart, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(1, uvMinmimum);
#if LIGHTING
	v.v_WorldPos = mul(vec4(startPosition + trailRightStart, 1.0), g_ModelMatrix);
#endif
#if REFRACT
	ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
	OUT.Append(v);

#if TRAILSUBDIVISION != 0
	float subDivStep = 1.0 / (TRAILSUBDIVISION + 1);
	float subDivCounter = subDivStep;
	for (int s = 0; s < TRAILSUBDIVISION; ++s)
	{
		float s = smoothstep(0, 1, subDivCounter);
		vec3 midPosition = cubicBezier(startPosition, CPStart, CPEnd, endPosition, s);
		float midUV = mix(uvMinmimum, uvMaximum, s);
		vec3 midRight = mix(trailRightStart, trailRightEnd, s);
		
		v.gl_Position = mul(vec4(midPosition - midRight, 1.0), g_ModelViewProjectionMatrix);
		v.v_TexCoord.xy = vec2(0, midUV);
#if REFRACT || LIGHTING
		right = mul(midRight, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
		v.v_WorldPos = mul(vec4(midPosition - midRight, 1.0), g_ModelMatrix);
		v.v_WorldRight = right;
#endif
#if REFRACT
		ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
		OUT.Append(v);
		v.gl_Position = mul(vec4(midPosition + midRight, 1.0), g_ModelViewProjectionMatrix);
		v.v_TexCoord.xy = vec2(1, midUV);
#if LIGHTING
		v.v_WorldPos = mul(vec4(midPosition + midRight, 1.0), g_ModelMatrix);
#endif
#if REFRACT
		ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
		OUT.Append(v);
		subDivCounter += subDivStep;
	}
#endif

	v.gl_Position = mul(vec4(endPosition - trailRightEnd, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(0, uvMaximum);
#if REFRACT || LIGHTING
	right = mul(trailRightEnd, CAST3X3(g_ModelMatrix));
#endif
#if LIGHTING
	v.v_WorldPos = mul(vec4(startPosition - trailRightEnd, 1.0), g_ModelMatrix);
	v.v_WorldRight = right;
#endif
#if REFRACT
	ComputeScreenRefractionTangents(v.gl_Position.xyw, right, cross(right, eyeDirection), v.v_ScreenCoord, v.v_ScreenTangents);
#endif
	OUT.Append(v);
	v.gl_Position = mul(vec4(endPosition + trailRightEnd, 1.0), g_ModelViewProjectionMatrix);
	v.v_TexCoord.xy = vec2(1, uvMaximum);
#if LIGHTING
	v.v_WorldPos = mul(vec4(endPosition + trailRightEnd, 1.0), g_ModelMatrix);
#endif
#if REFRACT
	ComputeScreenRefractionCoord(v.gl_Position.xyw, v.v_ScreenCoord);
#endif
	OUT.Append(v);
#endif
}





