
// [COMBO] {"material":"ui_editor_properties_reflection","combo":"REFLECTION","type":"options","default":1}

uniform float g_Frametime;
uniform vec4 g_Texture0Resolution;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_collision_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1","painttexturescale":1}

uniform float g_RippleSpeed; // {"material":"ripplespeed","label":"ui_editor_properties_ripple_speed","default":1.0,"range":[0,2]}
uniform float g_RippleDecay; // {"material":"rippledecay","label":"ui_editor_properties_ripple_decay","default":1.0,"range":[0,4]}

varying vec2 v_TexCoord;

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

vec4 sampleF(vec4 a, vec4 b, vec4 c)
{
	//float sb = step(length(a), length(b));
	//float sc = step(max(length(a), length(b)), length(c));
	//return mix(mix(a, b, sb), c, sc);
	//return a;
	//return ;
	return max(a, max(b, c));
	
	//vec4 f = max(a, max(b, c));
	
	//float maxAmt = max(f.x, max(f.y, max(f.z, f.w)));
	//float totalAmt = dot(CAST4(1.0), f);
	
	//if (totalAmt <= maxAmt)
	//	f *= 0.95;
	//return f;
}

void main() {

	vec2 srcCoords = v_TexCoord.xy;

	vec4 albedo = texSample2D(g_Texture0, srcCoords);
	vec2 simTexel = 1.0 / g_Texture0Resolution.xy;
	vec2 rippleOffset = simTexel * 100 * g_RippleSpeed * min(1.0 / 30.0, g_Frametime);
	
	vec2 insideRipple = rippleOffset * 1.61;
	vec2 outsideRipple = rippleOffset;
	
	float reflectUp = 0;
	float reflectDown = 0;
	float reflectLeft = 0;
	float reflectRight = 0;
	
#if REFLECTION
	reflectUp = step(1.0 - simTexel.y, srcCoords.y);
	reflectDown = step(srcCoords.y, simTexel.y);
	reflectLeft = step(1.0 - simTexel.x, srcCoords.x);
	reflectRight = step(srcCoords.x, simTexel.x);
#endif



#if MASK
	vec2 maskCoords = srcCoords;
	
#if PERSPECTIVE == 1
	maskCoords = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
#endif

	float invMaskCenter = 1.0 - step(0.5, texSample2D(g_Texture1, maskCoords).r);
	float maskUp = 0.0;
	float maskDown = 0.0;
	float maskLeft = 0.0;
	float maskRight = 0.0;
	
#if REFLECTION
	//simTexel *= 1.0;
	vec2 maskOffset = insideRipple;
	//vec2 maskOffset = simTexel;
	maskUp = texSample2D(g_Texture1, maskCoords + vec2(0, -maskOffset.y)).r * invMaskCenter;
	maskDown = texSample2D(g_Texture1, maskCoords + vec2(0, maskOffset.y)).r * invMaskCenter;
	maskLeft = texSample2D(g_Texture1, maskCoords + vec2(-maskOffset.x, 0)).r * invMaskCenter;
	maskRight = texSample2D(g_Texture1, maskCoords + vec2(maskOffset.x, 0)).r * invMaskCenter;
#endif

	reflectDown = step(0.5, reflectDown + maskUp);
	reflectUp = step(0.5, reflectUp + maskDown);
	reflectRight = step(0.5, reflectRight + maskLeft);
	reflectLeft = step(0.5, reflectLeft + maskRight);
#endif



	vec2 motionCoords = srcCoords;
	
	//vec4 cc = texSample2D(g_Texture0, motionCoords);
	//insideRipple = simTexel * 2; // * g_RippleSpeed * g_Frametime;

	vec4 uc = texSample2D(g_Texture0, motionCoords + vec2(0, -insideRipple.y));
	vec4 u00 = texSample2D(g_Texture0, motionCoords + vec2(-outsideRipple.x, -outsideRipple.y));
	vec4 u10 = texSample2D(g_Texture0, motionCoords + vec2(outsideRipple.x, -outsideRipple.y));
	
	vec4 dc = texSample2D(g_Texture0, motionCoords + vec2(0, insideRipple.y));
	vec4 d01 = texSample2D(g_Texture0, motionCoords + vec2(-outsideRipple.x, outsideRipple.y));
	vec4 d11 = texSample2D(g_Texture0, motionCoords + vec2(outsideRipple.x, outsideRipple.y));
	
	vec4 lc = texSample2D(g_Texture0, motionCoords + vec2(-insideRipple.x, 0));
	vec4 l00 = texSample2D(g_Texture0, motionCoords + vec2(-outsideRipple.x, -outsideRipple.y));
	vec4 l01 = texSample2D(g_Texture0, motionCoords + vec2(-outsideRipple.x, outsideRipple.y));
	
	vec4 rc = texSample2D(g_Texture0, motionCoords + vec2(insideRipple.x, 0));
	vec4 r10 = texSample2D(g_Texture0, motionCoords + vec2(outsideRipple.x, -outsideRipple.y));
	vec4 r11 = texSample2D(g_Texture0, motionCoords + vec2(outsideRipple.x, outsideRipple.y));
	
	vec4 up = sampleF(uc, u00, u10);
	vec4 down = sampleF(dc, d01, d11);
	vec4 left = sampleF(lc, l00, l01);
	vec4 right = sampleF(rc, r10, r11);


	vec4 sample;
	vec4 force = vec4(0, 0, 0, 0);

	float componentScale = 1 / 3.0;
	
	//vec4 reflectionMask = (CAST4(1.0) - vec4(reflectRight, reflectDown, reflectLeft, reflectUp));
	
	//force += up;
	//force += down;
	//force += left;
	//force += right;
	force.xzy += up.xzy;
	force.xzw += down.xzw;
	force.xyw += left.xyw;
	force.zyw += right.zyw;
	
	//force *= componentScale * reflectionMask;
	force *= componentScale;
	
	//force += up * componentScale;
	//force += down * componentScale;
	//force += left * componentScale;
	//force += right * componentScale;
	
#if REFLECTION
	vec4 forceCopy = force;
	
	float reflectionScale = 1.0;
	
	force.y = mix(force.y, forceCopy.w * reflectionScale, reflectDown);
	//force.y *= 1.0 - reflectDown;
	//force.y += forceCopy.w * reflectionScale * reflectDown;
	//force.xzw *= 1.0 - reflectDown;
	
	force.w = mix(force.w, forceCopy.y * reflectionScale, reflectUp);
	//force.w *= 1.0 - reflectUp;
	//force.w += forceCopy.y * reflectionScale * reflectUp;
	//force.xyz *= 1.0 - reflectUp;
	
	force.x = mix(force.x, forceCopy.z * reflectionScale, reflectRight);
	//force.x *= 1.0 - reflectRight;
	//force.x += forceCopy.z * reflectionScale * reflectRight;
	//force.yzw *= 1.0 - reflectRight;
	
	force.z = mix(force.z, forceCopy.x * reflectionScale, reflectLeft);
	//force.z *= 1.0 - reflectLeft;
	//force.z += forceCopy.x * reflectionScale * reflectLeft;
	//force.xyw *= 1.0 - reflectLeft;
	
	//force *= reflectionMask;
	//force = normalize(force) * length(forceCopy);
#endif

	float decay = 1.5;

	float drop = max(1.001 / 255.0, decay / 255.0 * (g_Frametime / 0.02) * g_RippleDecay);
	force -= drop;
	
#if MASK
	force *= invMaskCenter;
#endif

	albedo = force;

	//albedo = vec4(0, 0, 0, 0);

	gl_FragColor = albedo;
	
	//			vec4 info = cc;
	//
	//			float average = (
	//				uc.r + lc.r + dc.r + rc.r
	//			) * 0.25;
	//
	//			info.g += (average - info.r) * 2.0;
	//			info.g *= 0.95;
	//			//info.r *= 0.995;
	//			info.r += info.g;
				
#if MASK
	//info.r *= invMaskCenter;
#endif
	//			gl_FragColor = vec4(info.rg, 0, 1);
	//gl_FragColor = texSample2D(g_Texture0, srcCoords) - drop;
}
