
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":2,"require":{"WRITEALPHA":0}}
// [COMBO] {"material":"ui_editor_properties_transform","combo":"TRANSFORMUV","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_transform_repeat","combo":"TRANSFORMREPEAT","type":"options","default":0,"options":{"ui_editor_properties_clip":0,"ui_editor_properties_repeat":1,"ui_editor_properties_clamp_uvs":2},"require":{"TRANSFORMUV":1}}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_number_of_textures","combo":"NUMBLENDTEXTURES","type":"options","default":1,"options":{"1":1,"2":2,"3":3,"4":4,"5":5,"6":6}}

#include "common_blending.h"

varying vec4 v_TexCoord;

#if NUMBLENDTEXTURES >= 2
varying vec4 v_TexCoord23;
#endif

#if NUMBLENDTEXTURES >= 4
varying vec4 v_TexCoord45;
#endif

#if NUMBLENDTEXTURES >= 6
varying vec2 v_TexCoord6;
#endif

uniform float g_Multiply; // {"material":"multiply","label":"ui_editor_properties_blend_amount","default":1,"range":[0.0, 1.0]}
uniform float g_Multiply2; // {"material":"multiply2","label":"ui_editor_properties_blend_amount_2","default":1,"range":[0.0, 1.0]}
uniform float g_Multiply3; // {"material":"multiply3","label":"ui_editor_properties_blend_amount_3","default":1,"range":[0.0, 1.0]}
uniform float g_Multiply4; // {"material":"multiply4","label":"ui_editor_properties_blend_amount_4","default":1,"range":[0.0, 1.0]}
uniform float g_Multiply5; // {"material":"multiply5","label":"ui_editor_properties_blend_amount_5","default":1,"range":[0.0, 1.0]}
uniform float g_Multiply6; // {"material":"multiply6","label":"ui_editor_properties_blend_amount_6","default":1,"range":[0.0, 1.0]}
uniform float g_AlphaMultiply; // {"material":"alpha","label":"ui_editor_properties_alpha","default":1,"range":[0.0, 1.0]}

#if OPACITYMASK == 1
varying vec2 v_TexCoordOpacity;
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture7; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"OPACITYMASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}

#if NUMBLENDTEXTURES >= 2
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
#endif

#if NUMBLENDTEXTURES >= 3
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
#endif

#if NUMBLENDTEXTURES >= 4
uniform sampler2D g_Texture4; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
#endif

#if NUMBLENDTEXTURES >= 5
uniform sampler2D g_Texture5; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
#endif

#if NUMBLENDTEXTURES >= 6
uniform sampler2D g_Texture6; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
#endif

vec4 PerformBlend(vec4 albedo, vec4 blendColors, float blendAlpha)
{
#if WRITEALPHA
	float newAlpha = (albedo.a * (1.0 - blendAlpha) + blendColors.a * blendAlpha);

	vec4 input = albedo;
	
	albedo.rgb = albedo.rgb * albedo.a * (1.0 - blendAlpha) + blendColors.rgb * blendColors.a * blendAlpha;

	vec3 srcRgb = mix(blendColors.rgb, input.rgb, step(0.01, input.a) * (1.0 - blendColors.a * blendAlpha));
	vec3 dstRgb = mix(input.rgb, blendColors.rgb, step(0.01, blendColors.a * (1.0 - input.a * (1.0 - blendAlpha))));
	albedo.rgb += mix(srcRgb, dstRgb, blendAlpha) * (1.0 - newAlpha);

	albedo.a = newAlpha;
#else
	blendAlpha *= blendColors.a;

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, blendColors.rgb, blendAlpha);
#endif
	return albedo;
}

float GetUVBlend(vec2 uv)
{
#if TRANSFORMUV == 1 && TRANSFORMREPEAT == 0
	return step(0.99, dot(step(CAST2(0.0), uv) * step(uv, CAST2(1.0)), CAST2(0.5)));
#endif
	return 1.0;
}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	vec2 blendUV = v_TexCoord.zw;
#if TRANSFORMUV == 1 && TRANSFORMREPEAT == 1
	blendUV = frac(blendUV);
#endif

	vec4 blendColors = texSample2D(g_Texture1, blendUV);
	float blend = 1.0;

#if OPACITYMASK == 1
	blend *= texSample2D(g_Texture7, v_TexCoordOpacity).r;
#endif

	blend = GetUVBlend(blendUV) * blend;
	float blendAlpha = blend * g_Multiply;
	albedo = PerformBlend(albedo, blendColors, blendAlpha);

#if NUMBLENDTEXTURES >= 2
	blendUV =  frac(v_TexCoord23.xy);
	blendColors = texSample2D(g_Texture2, blendUV);
	
	albedo = PerformBlend(albedo, blendColors, GetUVBlend(blendUV) * blend * g_Multiply2);
#endif

#if NUMBLENDTEXTURES >= 3
	blendUV =  frac(v_TexCoord23.zw);
	blendColors = texSample2D(g_Texture3, blendUV);
	albedo = PerformBlend(albedo, blendColors, GetUVBlend(blendUV) * blend * g_Multiply3);
#endif

#if NUMBLENDTEXTURES >= 4
	blendUV =  frac(v_TexCoord45.xy);
	blendColors = texSample2D(g_Texture4, blendUV);
	albedo = PerformBlend(albedo, blendColors, GetUVBlend(blendUV) * blend * g_Multiply4);
#endif

#if NUMBLENDTEXTURES >= 5
	blendUV =  frac(v_TexCoord45.zw);
	blendColors = texSample2D(g_Texture5, blendUV);
	albedo = PerformBlend(albedo, blendColors, GetUVBlend(blendUV) * blend * g_Multiply5);
#endif

#if NUMBLENDTEXTURES >= 6
	blendUV =  frac(v_TexCoord6.xy);
	blendColors = texSample2D(g_Texture6, blendUV);
	albedo = PerformBlend(albedo, blendColors, GetUVBlend(blendUV) * blend * g_Multiply6);
#endif

	gl_FragColor = albedo;
}
