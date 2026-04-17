
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}
// [COMBO] {"material":"ui_editor_properties_refract","combo":"REFRACT","type":"options","default":1}

#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_flow_map","mode":"flowmask","default":"util/noflow"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_albedo","default":"util/clouds_256"}
uniform float g_Time;

uniform float g_FlowSpeed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.01, 1]}
uniform float g_FlowPhaseScale; // {"material":"phasescale","label":"ui_editor_properties_phase_scale","default":1,"range":[0.01, 10]}

uniform float g_CloudsAlpha; // {"material":"alpha","label":"ui_editor_properties_alpha","default":2.0,"range":[0.01, 10]}
uniform float g_CloudThreshold; // {"material":"threshold","label":"ui_editor_properties_threshold","default":0,"range:":[0,1]}
uniform float g_CloudFeather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.5,"range":[0.01,1]}
uniform float g_CloudLOD; // {"material":"smoothness","label":"ui_editor_properties_smoothness","default":0.0,"range":[0, 5]}
uniform float g_CloudScale; // {"material":"scale","label":"ui_editor_properties_scale","default":2.0,"range":[0.01, 10]}
uniform float g_Distortion; // {"material":"distortion","label":"ui_editor_properties_distortion","default":1.0,"range":[0.01, 10]}

uniform vec3 g_Color1; // {"material":"colorstart","label":"ui_editor_properties_color_start","default":"1 0.25 0","type":"color"}
uniform vec3 g_Color2; // {"material":"colorend","label":"ui_editor_properties_color_end","default":"1 0.8 0","type":"color"}

void main() {

	vec2 flowColors = texSample2D(g_Texture1, v_TexCoord.zw).rg;
	vec2 flowMask = (flowColors.rg - vec2(0.498, 0.498)) * 2.0;
	
	float scaledTime = g_Time * g_FlowSpeed;
	vec2 cycles = vec2(	frac(scaledTime),
						frac(scaledTime + 0.5));
	
	float blend = 2 * abs(cycles.x - 0.5);
	
	vec2 flowUVOffset1 = g_CloudScale * flowMask * 0.15 * (cycles.x - 0.5);
	vec2 flowUVOffset2 = g_CloudScale * flowMask * 0.15 * (cycles.y - 0.5);
	
	float cloudBackground = texSample2DLod(g_Texture2, v_TexCoord.xy * g_CloudScale + scaledTime * 0.1, g_CloudLOD).r;

	float cloud0 = texSample2DLod(g_Texture2, v_TexCoord.xy * g_CloudScale + flowUVOffset1, g_CloudLOD).r;
	float cloud1 = texSample2DLod(g_Texture2, v_TexCoord.xy * g_CloudScale + flowUVOffset2, g_CloudLOD).r;
	float streamNoise = mix(cloud0, cloud1, blend);
	
	//streamNoise = cloudBackground * streamNoise;
	

	vec2 baseUV = v_TexCoord.xy;
	float flowMaskLength = pow(length(flowMask), 2.0);
	
#if REFRACT
	baseUV += mix(flowMask, -flowMask, streamNoise) * cloudBackground * 0.5 * streamNoise * flowMaskLength * g_Distortion;
#endif

	vec4 albedo = texSample2D(g_Texture0, baseUV);

	streamNoise = frac(streamNoise + scaledTime * 0.2);
	
	//float blendNoise = smoothstep(0, 0.5, streamNoise) * smoothstep(1.0, 0.5, streamNoise);
	//vec3 cloudColor = mix(g_Color2, g_Color1, blendNoise);
	//blendNoise = smoothstep(g_CloudThreshold, g_CloudThreshold + g_CloudFeather, blendNoise);
	//float streamBlend = flowMaskLength * g_CloudsAlpha * (blendNoise);
	
	
	float colorNoise = smoothstep(0, 0.5, streamNoise) * smoothstep(1.0, 0.5, streamNoise);
	vec3 cloudColor = mix(g_Color2, g_Color1, colorNoise);
	float blendNoise = mix(colorNoise * flowMaskLength, 1.0, pow(flowMaskLength, 4.0));
	blendNoise = smoothstep(g_CloudThreshold, g_CloudThreshold + g_CloudFeather, blendNoise);

	float streamBlend = g_CloudsAlpha * blendNoise;
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, cloudColor, streamBlend);
	

	gl_FragColor = albedo;
}
