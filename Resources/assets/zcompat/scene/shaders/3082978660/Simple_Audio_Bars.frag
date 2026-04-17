// [COMBO] {"material":"Position","combo":"SHAPE","type":"options","default":0,"options":{"Bottom":0,"Top":1,"Left":2,"Right":3,"Circle - Inner":4,"Circle - Outer":5,"Center - L/R":6,"Center - U/D":7,"Stereo - L/R":8,"Stereo - U/D":9}}
// [COMBO] {"material":"Transparency","combo":"TRANSPARENCY","type":"options","default":1,"options":{"Preserve original":0,"Replace original":1,"Add to original":2,"Subtract from original":3,"Intersect original":4,"Fully opaque":5}}
// [COMBO] {"material":"Frequency Resolution","combo":"RESOLUTION","type":"options","default":32,"options":{"16":16,"32":32,"64":64}}
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}
// [COMBO] {"material":"Smooth curve","combo":"A_SMOOTH_CURVE","type":"options","default":0}
// [COMBO] {"material":"Anti-aliasing","combo":"ANTIALIAS","type":"options","default":0}
// [COMBO] {"material":"Hide Below Lower Bounds","combo":"CLIP_LOW","type":"options","default":0}
// [COMBO] {"material":"Hide Above Upper Bounds","combo":"CLIP_HIGH","type":"options","default":0}

#include "common.h"
#include "common_blending.h"

#define DEG2RAD 0.01745329251994329576923690768489 // 2 * PI / 360
#define DEG2PCT 0.0027777777777777777777777777777 // 1 / 360

// Same as GLSL's modulo function. Return value's sign is equivalent to the y value's sign.
float mod2(float x, float y) { return x - y * floor(x/y); }

varying vec2 v_TexCoord;

uniform float u_BarCount; // {"material":"Bar Count","default":32,"range":[1, 200]}
uniform vec2 u_BarBounds; // {"material":"Lower/Upper Bar Bounds","linked":true,"default":"0.0, 1.0","range":[0,1]}
uniform vec2 u_CircleAngles; // {"material":"Circle Start/End Angles","linked":true,"default":"0.0, 360.0","range":[0,360]}
uniform vec3 u_BarColor; // {"default":"1 1 1","material":"Bar Color","type":"color"}
uniform float u_BarOpacity; // {"default":"1","material":"ui_editor_properties_opacity"}
uniform float u_BarSpacing; // {"default":"0.1","material":"Bar Spacing"}
uniform vec2 u_AASmoothness; // {"default":"0.02, 0.02","material":"Anti-alias blurring","range":[0.01,0.1],"linked":true}


uniform sampler2D g_Texture0; // {"material":"previous","label":"Prev","hidden":true}


#if RESOLUTION == 16
uniform float g_AudioSpectrum16Left[16];
uniform float g_AudioSpectrum16Right[16];
#endif

#if RESOLUTION == 32
uniform float g_AudioSpectrum32Left[32];
uniform float g_AudioSpectrum32Right[32];
#endif

#if RESOLUTION == 64
uniform float g_AudioSpectrum64Left[64];
uniform float g_AudioSpectrum64Right[64];
#endif



// Shape & Position
#define BOTTOM 0
#define TOP 1
#define LEFT 2
#define RIGHT 3
#define CIRCLE_INNER 4
#define CIRCLE_OUTER 5
#define CENTER_H 6
#define CENTER_V 7
#define STEREO_H 8
#define STEREO_V 9


// Transparency
#define PRESERVE 0
#define REPLACE 1
#define ADD 2
#define SUBTRACT 3
#define INTERSECT 4
#define REMOVE 5







void main() {
	
	// Define the audio sample arrays
#if RESOLUTION == 16
#define u_AudioSpectrumLeft g_AudioSpectrum16Left
#define u_AudioSpectrumRight g_AudioSpectrum16Right
#endif
#if RESOLUTION == 32
#define u_AudioSpectrumLeft g_AudioSpectrum32Left
#define u_AudioSpectrumRight g_AudioSpectrum32Right
#endif
#if RESOLUTION == 64
#define u_AudioSpectrumLeft g_AudioSpectrum64Left
#define u_AudioSpectrumRight g_AudioSpectrum64Right
#endif



	// Map the coordinates to the selected shape
#if SHAPE == BOTTOM
	vec2 shapeCoord = v_TexCoord;
#endif
#if SHAPE == TOP
	vec2 shapeCoord = v_TexCoord;
	shapeCoord.y = 1.0 - shapeCoord.y;
#endif
#if SHAPE == LEFT
	vec2 shapeCoord = v_TexCoord.yx;
	shapeCoord.y = 1.0 - shapeCoord.y;
#endif
#if SHAPE == RIGHT
	vec2 shapeCoord = v_TexCoord.yx;
#endif
#if SHAPE == CENTER_H
	vec2 shapeCoord = v_TexCoord.yx;
	shapeCoord.y = frac(0.5 - shapeCoord.y);
#endif
#if SHAPE == CENTER_V
	vec2 shapeCoord = v_TexCoord.xy;
	shapeCoord.y = frac(0.5 - shapeCoord.y);
#endif
#if SHAPE == STEREO_H
	vec2 shapeCoord = v_TexCoord.yx;
#endif
#if SHAPE == STEREO_V
	vec2 shapeCoord = v_TexCoord.xy;
#endif
#if SHAPE == CIRCLE_INNER || SHAPE == CIRCLE_OUTER
	vec2 circleCoord = (v_TexCoord - 0.5) * 2.0;
	vec2 shapeCoord;
	float startAngle = u_CircleAngles.x * DEG2PCT;
	float endAngle = u_CircleAngles.y * DEG2PCT;
	shapeCoord.x = (atan2(circleCoord.y, circleCoord.x) + M_PI) / M_PI_2;
	// Shift to start angle
	shapeCoord.x = mod2(shapeCoord.x - min(startAngle, endAngle), 1.0);
	// Scale to area between start and end angles
	// y = 1 / (abs((x - 1) % 4 - 2) - 1)
	shapeCoord.x = shapeCoord.x / (abs(mod2(endAngle - startAngle - 1.0, 4.0) - 2.0) - 1.0);
	// Keep coordinates positive. Adds 1.0 if the end is before the start.
	shapeCoord.x += float((endAngle - startAngle) < 0.0);
	shapeCoord.y = sqrt(circleCoord.x * circleCoord.x + circleCoord.y * circleCoord.y);
#if SHAPE == CIRCLE_INNER
	shapeCoord.y = 1.0 - shapeCoord.y;
#endif
#endif



	// Get the frequency for this pixel, ie where we will sample from in the audio spectrum array. 0 == lowest frequency, RESOLUTION == highest frequency.
#if A_SMOOTH_CURVE == 1
	float frequency = shapeCoord.x * float(RESOLUTION);
#else
	// BarDist == How far this pixel is from the center of the bar that it belongs to. 0 = right in the middle, 1 = right on the edge.
	float barDist = abs(frac(shapeCoord.x * u_BarCount) * 2.0 - 1.0);
	float frequency = floor(shapeCoord.x * u_BarCount) / u_BarCount * float(RESOLUTION);
#endif
	float barFreq1 = mod2(frequency, float(RESOLUTION));
	float barFreq2 = mod2((barFreq1 + 1.0), float(RESOLUTION));


	
	// Get the height of the bar
// STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ****** STEREO ******
#if SHAPE == STEREO_H || SHAPE == STEREO_V || SHAPE == CENTER_H || SHAPE == CENTER_V
	float barVolume1L = u_AudioSpectrumLeft[int(barFreq1)];
	float barVolume2L = u_AudioSpectrumLeft[int(barFreq2)];
	float barVolume1R = u_AudioSpectrumRight[int(barFreq1)];
	float barVolume2R = u_AudioSpectrumRight[int(barFreq2)];
	float barVolumeLeft = mix(barVolume1L, barVolume2L, smoothstep(0.0, 1.0, frac(frequency)));
	float barVolumeRight = mix(barVolume1R, barVolume2R, smoothstep(0.0, 1.0, frac(frequency)));

	bool isLeftChannel = shapeCoord.y < 0.49;
	bool isRightChannel = shapeCoord.y > 0.51;
	
	// bar = 1 if this pixel is inside a bar, 0 if outside
	float barHeightLeft = 0.5 * mix(u_BarBounds.x, u_BarBounds.y, barVolumeLeft);
	float barHeightRight = 0.5 * mix(u_BarBounds.x, u_BarBounds.y, barVolumeRight);
#if ANTIALIAS == 1
	float verticalSmoothingLeft = u_AASmoothness.y * 0.05, verticalSmoothingRight = verticalSmoothingLeft;
	verticalSmoothingLeft *= saturate(mix(0.0, 1.0, barVolumeLeft * 100.0)); // Don't blur when near 0 volume
	verticalSmoothingRight *= saturate(mix(0.0, 1.0, barVolumeRight * 100.0));
	float barLeft = smoothstep(shapeCoord.y - verticalSmoothingLeft, shapeCoord.y + verticalSmoothingLeft, barHeightLeft);
	float barRight = smoothstep(1.0 - shapeCoord.y - verticalSmoothingRight, 1.0 - shapeCoord.y + verticalSmoothingRight, barHeightRight);
#else
	float barLeft = float(step(shapeCoord.y, barHeightLeft));
	float barRight = float(step(1.0 - shapeCoord.y, barHeightRight));
#endif
#if SHAPE == CENTER_H || SHAPE == CENTER_V
	// Clip the L/R channels for center, so they don't wrap around.
	barLeft *= float(isLeftChannel);
	barRight *= float(isRightChannel);
#endif

	// Bounds Clipping (Stereo)
#if CLIP_LOW == 1
#if ANTIALIAS == 1
	barLeft *= 1.0 - smoothstep(shapeCoord.y - verticalSmoothingLeft, shapeCoord.y + verticalSmoothingLeft, 0.5 * u_BarBounds.x);
	barRight *= 1.0 - smoothstep(1.0 - shapeCoord.y - verticalSmoothingRight, 1.0 - shapeCoord.y + verticalSmoothingRight, 0.5 * u_BarBounds.x);
#else
	barLeft *= 1.0 - float(step(shapeCoord.y, 0.5 * u_BarBounds.x));
	barRight *= 1.0 - float(step(1.0 - shapeCoord.y, 0.5 * u_BarBounds.x));
#endif
#endif
#if CLIP_HIGH == 1
#if ANTIALIAS == 1
	barLeft *= smoothstep(shapeCoord.y - verticalSmoothingLeft, 1.0 - shapeCoord.y + verticalSmoothingLeft, u_BarBounds.y);
	barRight *= smoothstep(1.0 - shapeCoord.y - verticalSmoothingRight, 1.0 - shapeCoord.y + verticalSmoothingRight, u_BarBounds.y);
#else
	barLeft *= float(step(shapeCoord.y, u_BarBounds.y));
	barRight *= float(step(1.0 - shapeCoord.y, u_BarBounds.y));
#endif
#endif

	float bar = max(barLeft, barRight);


// NON-STEREO *********** NON-STEREO *********** NON-STEREO *********** NON-STEREO *********** NON-STEREO *********** NON-STEREO ***********
#else
	float barVolume1 = (u_AudioSpectrumLeft[int(barFreq1)] + u_AudioSpectrumRight[int(barFreq1)]) * 0.5;
	float barVolume2 = (u_AudioSpectrumLeft[int(barFreq2)] + u_AudioSpectrumRight[int(barFreq2)]) * 0.5;
	float barVolume = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, frac(frequency)));

	// How tall the bar is in the current pixel's column
	float barHeight = mix(u_BarBounds.x, u_BarBounds.y, barVolume);
	// bar = 1 if this pixel is inside a bar, 0 if outside
#if ANTIALIAS == 1
	float verticalSmoothing = u_AASmoothness.y * 0.05;
	verticalSmoothing *= saturate(mix(0.0, 1.0, barVolume * 100.0)); // Don't blur when near 0 volume
	float bar = smoothstep(1.0 - shapeCoord.y - verticalSmoothing, 1.0 - shapeCoord.y + verticalSmoothing, barHeight);
#else
	float bar = float(step(1.0 - shapeCoord.y, barHeight));
#endif

	// Bounds Clipping (Non-stereo)
#if CLIP_LOW == 1
#if ANTIALIAS == 1
	bar *= 1.0 - smoothstep(1.0 - shapeCoord.y - verticalSmoothing, 1.0 - shapeCoord.y + verticalSmoothing, u_BarBounds.x);
#else
	bar *= 1.0 - float(step(1.0 - shapeCoord.y, u_BarBounds.x));
#endif
#endif
#if CLIP_HIGH == 1
#if ANTIALIAS == 1
	bar *= smoothstep(1.0 - shapeCoord.y - verticalSmoothing, 1.0 - shapeCoord.y + verticalSmoothing, u_BarBounds.y);
#else
	bar *= float(step(1.0 - shapeCoord.y, u_BarBounds.y));
#endif
#endif

#endif // End of stereo vs non-stereo



	// Semi-circle clipping
#if SHAPE == CIRCLE_INNER || SHAPE == CIRCLE_OUTER
// #if ANTIALIAS == 1
// 	bar *= smoothstep(0.0, u_AASmoothness * 0.1, shapeCoord.x) * smoothstep(1.0, 1.0 - u_AASmoothness, shapeCoord.x * float(sign(endAngle - startAngle)));
// #else
	bar *= float((shapeCoord.x > 0.0) && (shapeCoord.x * float(sign(endAngle - startAngle)) < 1.0));
// #endif
#endif



	// Bar spacing
#if A_SMOOTH_CURVE != 1
#if ANTIALIAS == 1
	bar *= max(1.0 - float(step(0.01, u_BarSpacing)), smoothstep(barDist - u_AASmoothness.x, barDist + u_AASmoothness.x, (1.0 - u_BarSpacing)));
#else
	bar *= float(step(barDist, 1.0 - u_BarSpacing));
#endif
#endif

	vec3 finalColor = u_BarColor;
	
	// Get the existing pixel color
	vec4 scene = texSample2D(g_Texture0, v_TexCoord);

	// Apply blend mode
	finalColor = ApplyBlending(BLENDMODE, mix(finalColor.rgb, scene.rgb, scene.a), finalColor.rgb, bar * u_BarOpacity);



#if TRANSPARENCY == PRESERVE
	float alpha = scene.a;
#endif
#if TRANSPARENCY == REPLACE
	float alpha = bar * u_BarOpacity;
#endif
#if TRANSPARENCY == ADD
	float alpha = max(scene.a, bar * u_BarOpacity);
#endif
#if TRANSPARENCY == SUBTRACT
	float alpha = max(0.0, scene.a - bar * u_BarOpacity);
#endif
#if TRANSPARENCY == INTERSECT
	float alpha = scene.a * bar * u_BarOpacity;
#endif
#if TRANSPARENCY == REMOVE
	float alpha = u_BarOpacity;
#endif



	gl_FragColor = vec4(finalColor, alpha);
	//gl_FragColor = vec4(CAST3(shapeCoord.x), alpha);
}
