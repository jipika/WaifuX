
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":32}
// [COMBO] {"material":"ui_editor_properties_style","combo":"MODE","default":0,"options":{"ui_editor_properties_realistic":0,"ui_editor_properties_illustrative":1}}

#include "common_blending.h"

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_pattern","default":"pattern/voronoi_local"}
uniform sampler2D g_Texture5; // {"label":"ui_editor_properties_pattern_glow","default":"pattern/voronoi"}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_perlin_noise","default":"util/uniform_256"}
uniform sampler2D g_Texture4; // {"label":"ui_editor_properties_offset","default":"util/perlin_256"}
uniform float g_Time;

uniform float u_brightness; // {"material":"ui_editor_properties_brightness","default":1,"range":[0.1,5]}
uniform float u_glow; // {"material":"ui_editor_properties_glow","default":0.5,"range":[0.0,1.0]}
uniform float u_scale; // {"material":"ui_editor_properties_granularity","default":2,"range":[0.1,5]}
uniform float u_speed; // {"material":"ui_editor_properties_speed","default":1,"range":[0,5]}
uniform float u_timeoffset; // {"material":"ui_editor_properties_time_offset","default":0,"range":[-5,5]}
uniform float u_distortion; // {"material":"ui_editor_properties_distortion","default":1,"range":[0,2]}
uniform float u_chromatic; // {"material":"ui_editor_properties_chromatic_aberration","default":1,"range":[0,2]}
uniform float u_blur; // {"material":"ui_editor_properties_blur","default":0,"range":[0,1]}
uniform vec3 u_color1; // {"material":"ui_editor_properties_color_start","default":"0.7 0.9 1","type":"color"}
uniform vec3 u_color2; // {"material":"ui_editor_properties_color_end","default":"0.4 0.6 1","type":"color"}

uniform vec4 g_Texture0Resolution;

varying vec4 v_TexCoord;

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float mask = 1.0;

	float ratio = g_Texture0Resolution.x / g_Texture0Resolution.y;
	vec2 causticsCoords = v_TexCoord.xy;

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif

#if PERSPECTIVE == 1
	causticsCoords = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
	mask *= step(abs(causticsCoords.x - 0.5), 0.5);
	mask *= step(abs(causticsCoords.y - 0.5), 0.5);
#endif

	causticsCoords.x *= ratio;
	causticsCoords *= u_scale;

	vec2 noiseCoords = causticsCoords;
	vec2 noiseCoords2 = causticsCoords;
	vec2 blendCoords = causticsCoords;
	vec2 shiftCoords = causticsCoords;

	noiseCoords *= 0.02;
	noiseCoords2 *= 0.0333;
	blendCoords *= 0.01333;
	shiftCoords *= 0.05;

	float time = g_Time * u_speed + u_timeoffset;
	noiseCoords.x += time * 0.005;
	noiseCoords2.y += time * 0.004111;
	blendCoords += time * 0.003777;
	shiftCoords += time * 0.01;

	vec4 shiftColor = texSample2D(g_Texture4, shiftCoords) * 2.0 - 1.0;
	vec4 noiseColor = texSample2D(g_Texture3, noiseCoords) * 2.0 - 1.0;
	vec4 noiseColor2 = texSample2D(g_Texture3, noiseCoords2) * 2.0 - 1.0;

	causticsCoords += noiseColor.xy * 0.025 * u_distortion;
	causticsCoords += noiseColor2.xy * 0.025 * u_distortion;
	causticsCoords += shiftColor.rg * u_distortion;

	vec2 causticsCoordsLeft = causticsCoords;
	vec2 causticsCoordsRight = causticsCoords;
	causticsCoordsLeft.x -= 0.01 * u_chromatic;
	causticsCoordsRight.x += 0.01 * u_chromatic;

	vec3 caustics = vec3(texSample2D(g_Texture2, causticsCoordsLeft).r,
						texSample2D(g_Texture2, causticsCoords).r,
						texSample2D(g_Texture2, causticsCoordsRight).r);

	float glowSample = texSample2D(g_Texture5, causticsCoords).r;
	vec4 blendColor = texSample2D(g_Texture3, blendCoords);
	
	caustics = mix(caustics, CAST3(glowSample), u_blur);

#if MODE == 1
	float causticsSample = caustics.y;
	float blendThreshold = max(0.3, blendColor.x - shiftColor.x);

	float particleNoise = texSample2D(g_Texture3, shiftCoords).r;
	float particleSample = smoothstep(blendThreshold, blendThreshold - 0.001, causticsSample) * step(0.3, particleNoise * causticsSample);
	causticsSample = smoothstep(blendThreshold, blendThreshold + 0.001, causticsSample) + particleSample;
	causticsSample = saturate(causticsSample + glowSample * u_glow);

	vec3 causticsColor = u_brightness * mix(u_color1, u_color2, smoothstep(0.0, 0.5, blendColor.x));
#else
	float causticsSample = dot(caustics, CAST3(0.33333));
	causticsSample = smoothstep(blendColor.x * 0.8, 1.0 - blendColor.y * 0.2, causticsSample + glowSample * u_glow);

	vec3 causticsColor = u_brightness * mix(u_color1, u_color2, blendColor.x);

	causticsColor.rgb *= caustics;
#endif

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, causticsColor, mask * causticsSample);

	gl_FragColor = albedo;
}
