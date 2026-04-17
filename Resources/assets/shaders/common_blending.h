
vec4 Desaturate(vec3 color, float Desaturation)
{
	vec3 grayXfer = vec3(0.3, 0.59, 0.11);
	vec3 gray = CAST3(dot(grayXfer, color));
	return vec4(mix(color, gray, Desaturation), 1.0);
}

vec3 RGBToHSL(vec3 color)
{
#ifdef HDR
	color = saturate(color);
#endif

	vec3 hsl;
	float fmin = min(min(color.r, color.g), color.b);
	float fmax = max(max(color.r, color.g), color.b);
	float delta = fmax - fmin;
	hsl.z = (fmax + fmin) / 2.0;

	if (delta == 0.0)
	{
		hsl.x = 0.0;
		hsl.y = 0.0;
	}
	else
	{
		if (hsl.z < 0.5)
			hsl.y = delta / (fmax + fmin);
		else
			hsl.y = delta / (2.0 - fmax - fmin);
		float deltaR = (((fmax - color.r) / 6.0) + (delta / 2.0)) / delta;
		float deltaG = (((fmax - color.g) / 6.0) + (delta / 2.0)) / delta;
		float deltaB = (((fmax - color.b) / 6.0) + (delta / 2.0)) / delta;
		if (color.r == fmax )
			hsl.x = deltaB - deltaG;
		else if (color.g == fmax)
			hsl.x = (1.0 / 3.0) + deltaR - deltaB;
		else if (color.b == fmax)
			hsl.x = (2.0 / 3.0) + deltaG - deltaR;

		if (hsl.x < 0.0)
			hsl.x += 1.0;
		else if (hsl.x > 1.0)
			hsl.x -= 1.0;
	}

	return hsl;
}

float HueToRGB(float f1, float f2, float hue)
{
	if (hue < 0.0)
		hue += 1.0;
	else if (hue > 1.0)
		hue -= 1.0;
	float res;
	if ((6.0 * hue) < 1.0)
		res = f1 + (f2 - f1) * 6.0 * hue;
	else if ((2.0 * hue) < 1.0)
		res = f2;
	else if ((3.0 * hue) < 2.0)
		res = f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
	else
		res = f1;
	return res;
}

vec3 HSLToRGB(vec3 hsl)
{
	vec3 rgb;
	if (hsl.y == 0.0)
		rgb = CAST3(hsl.z);
	else
	{
		float f2;
		if (hsl.z < 0.5)
			f2 = hsl.z * (1.0 + hsl.y);
		else
			f2 = (hsl.z + hsl.y) - (hsl.y * hsl.z);
		float f1 = 2.0 * hsl.z - f2;
		rgb.r = HueToRGB(f1, f2, hsl.x + (1.0/3.0));
		rgb.g = HueToRGB(f1, f2, hsl.x);
		rgb.b= HueToRGB(f1, f2, hsl.x - (1.0/3.0));
	}
	
	return rgb;
}

vec3 ContrastSaturationBrightness(vec3 color, float brt, float sat, float con)
{
	const float AvgLumR = 0.5;
	const float AvgLumG = 0.5;
	const float AvgLumB = 0.5;
	
	const vec3 LumCoeff = vec3(0.2125, 0.7154, 0.0721);
	
	vec3 AvgLumin = vec3(AvgLumR, AvgLumG, AvgLumB);
	vec3 brtColor = color * brt;
	vec3 intensity = CAST3(dot(brtColor, LumCoeff));
	vec3 satColor = mix(intensity, brtColor, sat);
	vec3 conColor = mix(AvgLumin, satColor, con);
	return conColor;
}

#define BlendLinearDodgef(base, blend) (base + blend)
#define BlendLinearBurnf(base, blend) max(base + blend - 1.0, 0.0)
#define BlendLightenf(base, blend) max(blend, base)
#define BlendDarkenf(base, blend) min(blend, base)
#define BlendLinearLightf(base, blend) (blend < 0.5 ? BlendLinearBurnf(base, (2.0 * blend)) : BlendLinearDodgef(base, (2.0 * (blend - 0.5))))
#define BlendScreenf(base, blend) (1.0 - ((1.0 - base) * (1.0 - blend)))
#define BlendOverlayf(base, blend) (base < 0.5 ? (2.0 * base * blend) : (1.0 - 2.0 * (1.0 - base) * (1.0 - blend)))
#define BlendSoftLightf(base, blend) ((blend < 0.5) ? (2.0 * base * blend + base * base * (1.0 - 2.0 * blend)) : (sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend)))
#define BlendColorDodgef(base, blend) ((blend == 1.0) ? blend : min(base / (1.0 - blend), 1.0))
#define BlendColorBurnf(base, blend) ((blend == 0.0) ? blend : max((1.0 - ((1.0 - base) / blend)), 0.0))
#define BlendVividLightf(base, blend) ((blend < 0.5) ? BlendColorBurnf(base, (2.0 * blend)) : BlendColorDodgef(base, (2.0 * (blend - 0.5))))
#define BlendPinLightf(base, blend) ((blend < 0.5) ? BlendDarkenf(base, (2.0 * blend)) : BlendLightenf(base, (2.0 *(blend - 0.5))))
#define BlendHardMixf(base, blend) ((BlendVividLightf(base, blend) < 0.5) ? 0.0 : 1.0)
#define BlendReflectf(base, blend) ((blend == 1.0) ? blend : min(base * base / (1.0 - blend), 1.0))
#define BlendNormal(base, blend) (blend)
#define BlendLighten BlendLightenf
#define BlendDarken	 BlendDarkenf
#define BlendMultiply(base, blend) (base * blend)
#define BlendAverage(base, blend) ((base + blend) / 2.0)
#define BlendAdd(base, blend) min(base + blend, CAST3(1.0))
#define BlendSubstract(base, blend) max(base + blend - CAST3(1.0), CAST3(0.0))
#define BlendDifference(base, blend) abs(base - blend)
#define BlendNegation(base, blend) (CAST3(1.0) - abs(CAST3(1.0) - base - blend))
#define BlendExclusion(base, blend) (base + blend - 2.0 * base * blend)
#define BlendScreen(base, blend) vec3(BlendScreenf(base.r, blend.r), BlendScreenf(base.g, blend.g), BlendScreenf(base.b, blend.b))
#define BlendOverlay(base, blend) vec3(BlendOverlayf(base.r, blend.r), BlendOverlayf(base.g, blend.g), BlendOverlayf(base.b, blend.b))
#define BlendSoftLight(base, blend) vec3(BlendSoftLightf(base.r, blend.r), BlendSoftLightf(base.g, blend.g), BlendSoftLightf(base.b, blend.b))
#define BlendHardLight(base, blend) BlendOverlay(blend, base)
#define BlendColorDodge(base, blend) vec3(BlendColorDodgef(base.r, blend.r), BlendColorDodgef(base.g, blend.g), BlendColorDodgef(base.b, blend.b))
#define BlendColorBurn(base, blend) vec3(BlendColorBurnf(base.r, blend.r), BlendColorBurnf(base.g, blend.g), BlendColorBurnf(base.b, blend.b))
#define BlendLinearLight(base, blend) vec3(BlendLinearLightf(base.r, blend.r), BlendLinearLightf(base.g, blend.g), BlendLinearLightf(base.b, blend.b))
#define BlendVividLight(base, blend) vec3(BlendVividLightf(base.r, blend.r), BlendVividLightf(base.g, blend.g), BlendVividLightf(base.b, blend.b))
#define BlendPinLight(base, blend) vec3(BlendPinLightf(base.r, blend.r), BlendPinLightf(base.g, blend.g), BlendPinLightf(base.b, blend.b))
#define BlendHardMix(base, blend) vec3(BlendHardMixf(base.r, blend.r), BlendHardMixf(base.g, blend.g), BlendHardMixf(base.b, blend.b))
#define BlendReflect(base, blend) vec3(BlendReflectf(base.r, blend.r), BlendReflectf(base.g, blend.g), BlendReflectf(base.b, blend.b))
#define BlendGlow(base, blend) BlendReflect(blend, base)
#define BlendPhoenix(base, blend) (min(base, blend) - max(base, blend) + CAST3(1.0))
#define BlendOpacity(base, blend, F, O) mix(base, F(base, blend), O)
#define BlendLinearDodge(base, blend) min(base + blend, CAST3(1.0))
#define BlendLinearBurn(base, blend) max(base + blend - CAST3(1.0), CAST3(0.0))
#define BlendTint(base, blend) (CAST3(max(base.x, max(base.y, base.z))) * blend)

vec3 BlendHue(vec3 base, vec3 blend)
{
	vec3 baseHSL = RGBToHSL(base);
	return HSLToRGB(vec3(RGBToHSL(blend).r, baseHSL.g, baseHSL.b));
}

vec3 BlendSaturation(vec3 base, vec3 blend)
{
	vec3 baseHSL = RGBToHSL(base);
	return HSLToRGB(vec3(baseHSL.r, RGBToHSL(blend).g, baseHSL.b));
}

vec3 BlendColor(vec3 base, vec3 blend)
{
	vec3 blendHSL = RGBToHSL(blend);
	return HSLToRGB(vec3(blendHSL.r, blendHSL.g, RGBToHSL(base).b));
}

vec3 BlendLuminosity(vec3 base, vec3 blend)
{
	vec3 baseHSL = RGBToHSL(base);
	return HSLToRGB(vec3(baseHSL.r, baseHSL.g, RGBToHSL(blend).b));
}

vec3 ApplyBlending(const int blendMode, in vec3 A, in vec3 B, in float opacity)
{
#if BLENDMODE == 1
	return mix(A,BlendDarken(A,B),opacity);
#endif
#if BLENDMODE == 2
	return mix(A,BlendMultiply(A,B),opacity);
#endif
#if BLENDMODE == 3
	return mix(A,BlendColorBurn(A,B),opacity);
#endif
#if BLENDMODE == 4
	return mix(A,BlendSubstract(A,B),opacity);
#endif
#if BLENDMODE == 5
	return min(A, B);
#endif
#if BLENDMODE == 6
	return mix(A,BlendLighten(A,B),opacity);
#endif
#if BLENDMODE == 7
	return mix(A,BlendScreen(A,B),opacity);
#endif
#if BLENDMODE == 8
	return mix(A,BlendColorDodge(A,B),opacity);
#endif
#if BLENDMODE == 9
	return mix(A,BlendAdd(A,B),opacity);
#endif
#if BLENDMODE == 10
	return max(A, B);
#endif
#if BLENDMODE == 11
	return mix(A,BlendOverlay(A,B),opacity);
#endif
#if BLENDMODE == 12
	return mix(A,BlendSoftLight(A,B),opacity);
#endif
#if BLENDMODE == 13
	return mix(A,BlendHardLight(A,B),opacity);
#endif
#if BLENDMODE == 14
	return mix(A,BlendVividLight(A,B),opacity);
#endif
#if BLENDMODE == 15
	return mix(A,BlendLinearLight(A,B),opacity);
#endif
#if BLENDMODE == 16
	return mix(A,BlendPinLight(A,B),opacity);
#endif
#if BLENDMODE == 17
	return mix(A,BlendHardMix(A,B),opacity);
#endif
#if BLENDMODE == 18
	return mix(A,BlendDifference(A,B),opacity);
#endif
#if BLENDMODE == 19
	return mix(A,BlendExclusion(A,B),opacity);
#endif
#if BLENDMODE == 20
	return mix(A,BlendSubstract(A,B),opacity);
#endif
#if BLENDMODE == 21
	return mix(A,BlendReflect(A,B),opacity);
#endif
#if BLENDMODE == 22
	return mix(A,BlendGlow(A,B),opacity);
#endif
#if BLENDMODE == 23
	return mix(A,BlendPhoenix(A,B),opacity);
#endif
#if BLENDMODE == 24
	return mix(A,BlendAverage(A,B),opacity);
#endif
#if BLENDMODE == 25
	return mix(A,BlendNegation(A,B),opacity);
#endif
#if BLENDMODE == 26
	return mix(A,BlendHue(A,B),opacity);
#endif
#if BLENDMODE == 27
	return mix(A,BlendSaturation(A,B),opacity);
#endif
#if BLENDMODE == 28
	return mix(A,BlendColor(A,B),opacity);
#endif
#if BLENDMODE == 29
	return mix(A,BlendLuminosity(A,B),opacity);
#endif
#if BLENDMODE == 30
	return mix(A,BlendTint(A,B),opacity);
#endif
#if BLENDMODE == 31
	return A+B*opacity;
#endif
#if BLENDMODE == 32
	return mix(A,A+A*B,opacity);
#endif
	return mix(A,BlendNormal(A,B),opacity);
}
