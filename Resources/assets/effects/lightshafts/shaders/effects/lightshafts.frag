
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31,"require":{"DIRECTDRAW":0}}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":0,"require":{"DIRECTDRAW":0}}
// [COMBO] {"material":"ui_editor_properties_direction","combo":"RAYMODE","type":"options","default":0,"options":{"ui_editor_properties_linear":0,"ui_editor_properties_radial":1,"ui_editor_properties_corner":2}}
// [COMBO] {"material":"ui_editor_properties_rendering","combo":"RENDERING","type":"options","default":0,"options":{"ui_editor_properties_color":0,"ui_editor_properties_gradient":1}}
// [COMBO] {"material":"ui_editor_properties_corner","combo":"RAYCORNER","type":"options","default":0,"options":{"ui_editor_properties_top_left":0,"ui_editor_properties_top_right":1,"ui_editor_properties_bottom_left":2,"ui_editor_properties_bottom_right":3},"require":{"RAYMODE":2}}

#include "common_fragment.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec3 v_TexCoordFx;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_noise","default":"util/noise"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_gradient_map","default":"gradient/gradient_iridescent","formatcombo":true,"require":{"RENDERING":1}}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1","require":{"DIRECTDRAW":0}}

uniform float g_Time;

uniform float g_Speed; // {"material":"rayspeed","label":"ui_editor_properties_speed","default":0.2,"range":[0.1, 1.0],"group":"ui_editor_properties_shape"}
uniform vec2 g_Scale; // {"material":"rayscale","label":"ui_editor_properties_scale","default":"0.5 0.1","linked":true,"range":[0.1, 2.0],"group":"ui_editor_properties_shape","group":"ui_editor_properties_shape"}
uniform float g_Smoothness; // {"material":"raysmoothness","label":"ui_editor_properties_smoothness","default":0.75,"range":[0.1, 1.0],"group":"ui_editor_properties_blending"}
uniform vec2 g_Feather; // {"material":"rayfeather","label":"ui_editor_properties_feather","default":"0.05 0.2","linked":true,"range":[0.0, 0.5],"group":"ui_editor_properties_blending"}
uniform float g_Radius; // {"material":"rayradius","label":"ui_editor_properties_radius","default":0.2,"range":[0.0, 1.0],"group":"ui_editor_properties_shape"}

uniform float g_NoiseScale; // {"material":"noisescale","label":"ui_editor_properties_noise_scale","default":1.0,"range":[0.0, 5.0],"group":"ui_editor_properties_shape"}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.33,"range":[0.0, 1.0],"group":"ui_editor_properties_shape"}

uniform float g_Intensity; // {"material":"colorwintensity","label":"ui_editor_properties_intensity","default":1,"range":[0.01, 10.0],"group":"ui_editor_properties_blending"}
uniform float g_Exponent; // {"material":"colorwexponent","label":"ui_editor_properties_exponent","default":1,"range":[0.2, 2.0],"group":"ui_editor_properties_blending"}
uniform vec3 g_ColorRaysStart; // {"material":"colorastart","label":"ui_editor_properties_color_start","default":"1 1 1","type":"color","group":"ui_editor_properties_blending"}
uniform vec3 g_ColorRaysEnd; // {"material":"colorend","label":"ui_editor_properties_color_end","default":"0.5 0.8 1","type":"color","group":"ui_editor_properties_blending"}
uniform float g_StartAngle; // {"material":"rayzstartangle","label":"ui_editor_properties_start_angle","default":0,"range":[0.0, 1.0],"group":"ui_editor_properties_blending"}
uniform float g_EndAngle; // {"material":"rayzzendangle","label":"ui_editor_properties_end_angle","default":1,"range":[0.0, 1.0],"group":"ui_editor_properties_blending"}

void main() {
	vec2 fxCoord = v_TexCoordFx.xy / v_TexCoordFx.z;
#if DIRECTDRAW
	vec4 albedo = CAST4(0.0);
#else
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
#endif

	float mask = step(0.0, v_TexCoordFx.z);
	vec2 shapeScale = g_Scale;

#if RAYMODE == 1
	vec2 rayCenter = vec2(0.5, 0.5);
	vec2 rayDelta = fxCoord - rayCenter;
	fxCoord.x = atan2(rayDelta.y, rayDelta.x) / 6.283185 + 0.5;

	fxCoord.y = length(rayDelta) * 2.0;
	//fxCoord.y += texSample2D(g_Texture1, vec2(fxCoord.x * 0.054111 * g_NoiseScale, 0)).r * g_NoiseAmount - (g_NoiseAmount * 0.5);
	fxCoord.y = smoothstep(g_Radius, 1.0, fxCoord.y);
	fxCoord.y = (fxCoord.y - 0.0001) * 1.00021;
	
	vec2 fxCoordRef = fxCoord;
	shapeScale.x *= 4;

	mask *= smoothstep(-0.00001 + g_StartAngle, g_StartAngle + g_Feather.x, fxCoord.x);
	mask *= smoothstep(g_EndAngle + 0.00001, g_EndAngle - g_Feather.x, fxCoord.x);
	//mask *= smoothstep(0.50001, 0.5 - g_Feather.x, abs(fxCoord.x - 0.5));
	mask *= smoothstep(0.50001, 0.5 - g_Feather.y, abs(fxCoord.y - 0.5));
#elif RAYMODE == 2
	vec2 rayCenter = vec2(0, 0);
	vec2 rayDelta = fxCoord - rayCenter;
#if RAYCORNER == 1
	rayDelta.x = 1.0 - rayDelta.x;
#elif RAYCORNER == 2
	rayDelta.y = 1.0 - rayDelta.y;
#elif RAYCORNER == 3
	rayDelta.y = 1.0 - rayDelta.y;
	rayDelta.x = 1.0 - rayDelta.x;
#endif
	fxCoord.x = atan2(rayDelta.y, rayDelta.x) / 6.283185 * 4;
	fxCoord.y = max(rayDelta.x, rayDelta.y);
	//fxCoord.y = length(rayDelta);
	fxCoord.y += texSample2D(g_Texture1, vec2(fxCoord.x * 0.054111 * g_NoiseScale, 0)).r * g_NoiseAmount - (g_NoiseAmount * 0.5);
	fxCoord.y = smoothstep(g_Radius, 1.0, fxCoord.y);
	
	vec2 fxCoordRef = fxCoord;
	shapeScale.x *= 4;

	mask *= smoothstep(0.50001, 0.5 - g_Feather.x, abs(fxCoord.x - 0.5));
	mask *= smoothstep(0.50001, 0.5 - g_Feather.y, abs(fxCoord.y - 0.5));
#else
	//fxCoord.y += texSample2D(g_Texture1, vec2(fxCoord.x * 0.054111 * g_NoiseScale, 0)).r * g_NoiseAmount - (g_NoiseAmount * 0.5);
	vec2 fxCoordRef = fxCoord;
	mask *= smoothstep(0.50001, 0.5 - g_Feather.x, abs(fxCoord.x - 0.5));
	mask *= smoothstep(0.50001, 0.5 - g_Feather.y, abs(fxCoord.y - 0.5));
#endif

	float grad = 1.0 - fxCoord.y;
	mask *= grad;

	vec2 fxCoord2 = fxCoord;
	fxCoord.xy *= vec2(0.054111 * shapeScale.x, 0.003111 * shapeScale.y);
	fxCoord2.xy *= vec2(0.07333 * shapeScale.x, 0.005967111 * shapeScale.y);

	fxCoord.xy += g_Time * g_Speed * vec2(0.003, 0.000375111);
	fxCoord2.xy -= g_Time * g_Speed * vec2(0.0047111, 0.0007399);

	float fx0 = texSample2D(g_Texture1, fxCoord).r;
	float fx1 = texSample2D(g_Texture1, fxCoord2).r;
	float fx = fx0 * fx1;
	fx = pow(fx, g_Exponent);

	fx = smoothstep((1.0 - g_Smoothness) * 0.29999, 0.3 + g_Smoothness * 0.7, fx);

#if RENDERING == 0
	vec3 fxColor = mix(g_ColorRaysStart, g_ColorRaysEnd, fxCoordRef.y);
#else
	vec2 gradientUVs = vec2(fxCoordRef.y, 0);
#if TEX2FORMAT == FORMAT_R8 || TEX2FORMAT == FORMAT_RG88
	vec3 gradColor = texSample2D(g_Texture2, gradientUVs).rrr;
#else
	vec3 gradColor = texSample2D(g_Texture2, gradientUVs).rgb;
#endif
	vec3 fxColor = gradColor;
#endif

#if MASK
	float maskSample = texSample2D(g_Texture3, v_TexCoord.zw).r;
	//albedo = mix(sample, albedo, mask);
	mask *= maskSample;
#endif

	fx *= mask;
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, fxColor * g_Intensity, fx);
	albedo.a = max(albedo.a, fx);

#if WRITEALPHA
	albedo.a = fx;
#endif

	gl_FragColor = albedo;
}
