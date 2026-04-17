
#include "common.h"

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_perlin_noise","default":"util/perlin_256"}

uniform float u_amount; // {"material":"ui_editor_properties_amount","default":0.1,"range":[0,0.2]}
uniform float u_direction; // {"material":"ui_editor_properties_direction","default":1.57079632679,"direction":true,"conversion":"rad2deg"}

varying vec4 v_TexCoord;
varying vec2 v_NoiseCoord;

void main() {
	float mask = 1.0;

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif

	vec3 noise = texSample2D(g_Texture2, v_NoiseCoord).rgb;

	vec2 uvs = v_TexCoord.xy;
	vec2 offset = vec2((noise.x * 2.0 - 1.0) * u_amount * mask, 0.0);
	offset = rotateVec2(offset, u_direction + 1.57079632679);
	uvs += offset;

#if MASK
	float dstMask = texSample2D(g_Texture1, v_TexCoord.zw + offset).r;
	uvs = mix(v_TexCoord.xy, uvs, dstMask);
#endif

	vec4 albedo = texSample2D(g_Texture0, uvs);

	gl_FragColor = albedo;
}
