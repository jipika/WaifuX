// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31}

#include "common.h"
#include "common_blending.h"

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_time_offset","mode":"opacitymask","combo":"OFFSET","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_gradient_map","default":"gradient/gradient_ferro_fluid"}

uniform float g_Time;
uniform float u_direction; // {"material":"ui_editor_properties_direction","default":1.57079632679,"direction":true,"conversion":"rad2deg"}
uniform float u_scale; // {"material":"ui_editor_properties_granularity","default":1,"range":[1,5]}
uniform float u_speed; // {"material":"ui_editor_properties_speed","default":0.1,"range":[0,5]}
uniform float u_delay; // {"material":"ui_editor_properties_delay","default":1,"range":[1,5]}
uniform float u_amount; // {"material":"ui_editor_properties_amount","default":1,"range":[0,5]}
uniform float u_timeoffsetScale; // {"material":"ui_editor_properties_timescale","default":0.05,"range":[0,1]}
uniform vec3 u_color; // {"material":"ui_editor_properties_color","default":"1 1 1","type":"color"}

varying vec4 v_TexCoord;
varying vec2 v_TexCoord2;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float mask = 1.0;
	float offset = 0.0;

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif

#if OFFSET
	offset = texSample2D(g_Texture2, v_TexCoord2.xy).r * u_timeoffsetScale;
#endif

	vec2 shimmerCoord = rotateVec2(v_TexCoord, -u_direction + 1.57079632679) * u_scale;
	shimmerCoord.x += u_speed * (g_Time + offset);
	shimmerCoord.x = saturate(frac(shimmerCoord.x / (u_scale * u_delay)) * u_scale * u_delay);

	vec3 shimmerColor = texSample2D(g_Texture3, frac(shimmerCoord));
	vec3 effectAlbedo = albedo.rgb * shimmerColor * u_color;

	effectAlbedo = ApplyBlending(BLENDMODE, albedo.rgb, effectAlbedo, 1.0);
	albedo.rgb = mix(albedo.rgb, effectAlbedo, mask * shimmerColor * u_amount);

	gl_FragColor = albedo;
}

