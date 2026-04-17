
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}
// [COMBO] {"material":"ui_editor_properties_transform","combo":"TRANSFORMUV","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_transform_repeat","combo":"TRANSFORMREPEAT","type":"options","default":0,"options":{"ui_editor_properties_clip":0,"ui_editor_properties_repeat":1,"ui_editor_properties_clamp_uvs":2}}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_edge_glow","combo":"EDGEGLOW","type":"options","default":0}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform float g_Multiply; // {"material":"multiply","label":"ui_editor_properties_blend_amount","default":1,"range":[0.0, 1.0]}
uniform float g_GradientScale; // {"material":"gradientscale","label":"ui_editor_properties_gradient_scale","default":0.05,"range":[0.01, 0.25]}
uniform float g_AlphaMultiply; // {"material":"alpha","label":"ui_editor_properties_alpha","default":1,"range":[0.0, 1.0]}

uniform float g_EdgeBrightness; // {"material":"edgebrightness","label":"ui_editor_properties_edge_brightness","default":1,"range":[0.0, 5.0]}
uniform vec3 g_EdgeColor; // {"material":"edgecolor","label":"ui_editor_properties_edge_color","default":"1 0.75 0","type":"color"}

#if OPACITYMASK == 1
varying vec2 v_TexCoordOpacity;
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_blend_texture","mode":"rgbmask","default":"util/white"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_gradient_mask","mode":"opacitymask","default":"util/clouds_256","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"OPACITYMASK","paintdefaultcolor":"0 0 0 1"}

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
	
	float gradient = texSample2D(g_Texture2, blendUV).r;
	blend = smoothstep(saturate(gradient - g_GradientScale), saturate(gradient + g_GradientScale), g_Multiply);

#if OPACITYMASK == 1
	float mask = texSample2D(g_Texture3, v_TexCoordOpacity).r;
	blend *= mask;
#endif

	float blendAlpha = GetUVBlend(blendUV) * blend * blendColors.a;
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, blendColors.rgb, blendAlpha);

#if EDGEGLOW
	float burnWidth = g_GradientScale * 0.5;
	float burnAmount = step(gradient - burnWidth, g_Multiply) *
		step(g_Multiply, gradient + burnWidth) *
		step(0.01, g_Multiply) *
		step(g_Multiply, 0.999);
#if OPACITYMASK == 1
	burnAmount *= mask;
#endif
	albedo.rgb = max(CAST3(0.0), mix(albedo.rgb, g_EdgeColor, burnAmount * g_EdgeBrightness));
#endif

#if WRITEALPHA
	albedo.a = blendColors.a * g_AlphaMultiply;
#endif

	gl_FragColor = albedo;
}
