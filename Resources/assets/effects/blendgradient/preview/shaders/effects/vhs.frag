
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":12}
// [COMBO] {"material":"ui_editor_properties_greyscale","combo":"GREYSCALE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_artifacts_negated","combo":"INVERTARTIFACTS","type":"options","default":1}

#include "common.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec2 v_TexCoordGlitchBase;
varying vec4 v_TexCoordGlitch;
varying vec4 v_TexCoordNoise;
varying vec4 v_TexCoordVHSNoise;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_noise","default":"util/noise"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","paintdefaultcolor":"0 0 0 1","combo":"MASK"}

uniform float g_Time;

uniform float g_NoiseScale; // {"material":"scale","label":"ui_editor_properties_scale","default":0.3,"range":[0.01, 1.0]}
uniform float g_NoiseAlpha; // {"material":"strength","label":"ui_editor_properties_alpha","default":1.0,"range":[0.0, 2.0]}
uniform float g_DistortionStrength; // {"material":"distortionstrength","label":"ui_editor_properties_distortion_strength","default":1.0,"range":[0.0, 2.0]}
uniform float g_DistortionSpeed; // {"material":"distortionspeed","label":"ui_editor_properties_distortion_speed","default":1,"range":[0.0, 2.0]}
uniform float g_DistortionWidth; // {"material":"distortionwidth","label":"ui_editor_properties_distortion_width","default":1.0,"range":[0.0, 2.0]}
uniform float g_ArtifactsScale; // {"material":"artifacts","label":"ui_editor_properties_artifacts","default":1.5,"range":[0.0, 3.0]}

void main() {
	float dblend = sin(g_Time);
	dblend = sign(dblend) * pow(abs(max(0.00001, dblend)), 4.0);
	vec2 distortion = vec2(dblend *
							g_DistortionStrength * 0.02 *
								smoothstep(0.01 * g_DistortionWidth, 0.0, abs(frac(g_Time * g_DistortionSpeed) - v_TexCoord.y)),
							0.0);
	distortion *= g_NoiseAlpha;

	vec4 albedo;
	float vhsBlend = 1.0;
	
#if MASK == 1
	vhsBlend *= texSample2D(g_Texture2, v_TexCoord.zw).r;
	vec4 orig = texSample2D(g_Texture0, v_TexCoord.xy + distortion * vhsBlend);
	albedo.ga = texSample2D(g_Texture0, v_TexCoordGlitchBase + distortion * vhsBlend).ga;
#else
	vec4 orig = texSample2D(g_Texture0, v_TexCoord.xy + distortion);
	albedo.ga = orig.ga;
#endif

	albedo.r = texSample2D(g_Texture0, v_TexCoordGlitch.xy + distortion).r;
	albedo.b = texSample2D(g_Texture0, v_TexCoordGlitch.zw + distortion).b;
	
	vec3 noise = texSample2D(g_Texture1, v_TexCoordNoise.xy).rgb;
	vec3 noise2 = texSample2D(g_Texture1, v_TexCoordNoise.zw).gbr;
	
#if GREYSCALE == 1
	noise = CAST3(greyscale(noise));
	noise2 = CAST3(greyscale(noise2));
#endif
	
	noise = saturate(noise * noise2);
	
	float blend = 0.1;
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, noise, blend);
	albedo.rgb = BlendOpacity(albedo.rgb, smoothstep(0.7, 1.0, noise), BlendLinearDodge, blend);
	
	vec2 vhsNoise = texSample2D(g_Texture1, v_TexCoordVHSNoise.xy).rg;
	vec2 vhsNoise2 = texSample2D(g_Texture1, v_TexCoordVHSNoise.zw).rg;

	float artifactLimiter = pow(max(g_ArtifactsScale, 0.0001), 0.2);
	float artifactsAlpha = step(0.001, g_NoiseScale) * step(0.9, vhsNoise.x * artifactLimiter) * step(0.9, vhsNoise2.x * artifactLimiter) * vhsNoise.y * vhsNoise2.y;
#if INVERTARTIFACTS
	albedo.rgb = mix(albedo.rgb, CAST3(1.0 - albedo.rgb), artifactsAlpha);
#else
	albedo.rgb += CAST3(artifactsAlpha);
#endif
	
	gl_FragColor = mix(orig, albedo, g_NoiseAlpha * vhsBlend);
}
