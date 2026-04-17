
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_ModelMatrixInverse;

uniform vec3 g_OrientationUp;
uniform vec3 g_OrientationRight;
uniform vec3 g_OrientationForward;

uniform vec3 g_ViewUp;
uniform vec3 g_ViewRight;
uniform vec3 g_EyePosition;

uniform vec4 g_RenderVar0;
uniform vec4 g_RenderVar1;
uniform vec4 g_Texture0Resolution;

#if REFRACT
uniform float g_RefractAmount; // {"material":"ui_editor_properties_refract_amount","default":0.05,"range":[-1,1]}
#endif

void ComputeParticleTangents(in vec3 rotation, out vec3 right, out vec3 up)
{
	vec3 rCos = cos(rotation);
	vec3 rSin = sin(rotation);
	// Apply particle rotation
	mat3 mRotation = mul(mul(
				mat3(rCos.z, -rSin.z, 0,
					rSin.z, rCos.z, 0,
					0, 0, 1),
				mat3(1, 0, 0,
					0, rCos.x, -rSin.x,
					0, rSin.x, rCos.x)),
				mat3(rCos.y, 0, rSin.y,
					0, 1, 0,
					-rSin.y, 0, rCos.y));
	// Apply screen orientation
	mRotation = mul(mRotation, mat3(g_OrientationRight, g_OrientationUp, g_OrientationForward));
	right = mul(vec3(1, 0, 0), mRotation);
	up = mul(vec3(0, 1, 0), mRotation);
}

void ComputeParticleTrailTangents(vec3 localPosition, vec3 localVelocity, out vec3 right, out vec3 up)
{
	//vec3 eyeDirection = mul(g_OrientationForward, CAST3X3(g_ModelMatrixInverse));
	vec3 eyeDirection = localPosition - mul(vec4(g_EyePosition, 1.0), g_ModelMatrixInverse).xyz;
	right = cross(eyeDirection, localVelocity);

	right = normalize(right);
	float trailLength = length(localVelocity);
	localVelocity /= trailLength;
	up = localVelocity * max(g_RenderVar0.z, min(trailLength * g_RenderVar0.x, g_RenderVar0.y));
}

vec3 ComputeParticlePosition(vec2 uvs, float textureRatio, vec4 positionAndSize, vec3 right, vec3 up)
{
	return positionAndSize.xyz +
		(positionAndSize.w * right * (uvs.x-0.5) -
		positionAndSize.w * up * (uvs.y-0.5) * textureRatio);
}

void ComputeSpriteFrame(float lifetime, out vec4 uvs, out vec2 uvFrameSize, out float frameBlend)
{
	float numFrames = g_RenderVar1.z;
	float frameWidth = g_RenderVar1.x;
	float frameHeight = g_RenderVar1.y;

	float currentFrame = floor(lifetime * numFrames);
	float nextFrame = min(numFrames - 1.0, currentFrame + 1.0);

#if SPRITESHEETBLENDNPOT
	float unpaddedWidth = g_Texture0Resolution.z / g_Texture0Resolution.x;
	float scaledFrameWidth = frameWidth / unpaddedWidth;
	uvs.y = floor(currentFrame * scaledFrameWidth) * frameHeight;
	uvs.x = frac(currentFrame * scaledFrameWidth) * unpaddedWidth;
	uvs.w = floor(nextFrame * scaledFrameWidth) * frameHeight;
	uvs.z = frac(nextFrame * scaledFrameWidth) * unpaddedWidth;
#else
	uvs.y = floor(currentFrame * frameWidth) * frameHeight;
	uvs.x = frac(currentFrame * frameWidth);
	uvs.w = floor(nextFrame * frameWidth) * frameHeight;
	uvs.z = frac(nextFrame * frameWidth);
#endif
	
	frameBlend = frac(lifetime * numFrames);
	uvFrameSize = vec2(frameWidth, frameHeight);
}

void ComputeScreenRefractionTangents(in vec3 projectedPositionXYW, in vec3 right, in vec3 up, out vec3 v_ScreenCoord, out vec4 v_ScreenTangents)
{
	v_ScreenCoord = projectedPositionXYW;
#ifdef HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif

	right = normalize(right);
	up = normalize(up);

	v_ScreenTangents.xy = vec2(dot(right, g_ViewRight),
								dot(up, g_ViewRight));
	v_ScreenTangents.zw = vec2(dot(right, g_ViewUp),
								dot(up, g_ViewUp));

#if REFRACT
	v_ScreenTangents *= g_RefractAmount;
#endif
}

void ComputeScreenRefractionCoord(in vec3 projectedPositionXYW, out vec3 v_ScreenCoord)
{
	v_ScreenCoord = projectedPositionXYW;
#ifdef HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif
}
