
// [COMBO] {"material":"ui_editor_properties_shading","combo":"SHADING","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":0}

#include "common.h"
#include "common_blending.h"

varying vec4 v_TexCoord;
varying vec4 v_TexCoordClouds;

uniform sampler2D g_Texture0; // {"material":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"ui_editor_properties_albedo","default":"util/clouds_256"}
uniform sampler2D g_Texture2; // {"material":"ui_editor_properties_opacity_mask","mode":"opacitymask","default":"util/white","combo":"MASK"}

uniform float g_CloudsAlpha; // {"material":"ui_editor_properties_alpha","default":1.0,"range":[0.01, 1]}
uniform float g_CloudThreshold; // {"material":"ui_editor_properties_threshold","default":0.2,"range:":[0,1]}
uniform float g_CloudFeather; // {"material":"ui_editor_properties_feather","default":0.1,"range":[0,1]}
uniform float g_CloudShading; // {"material":"ui_editor_properties_shading","default":0.5,"range":[0,1]}
uniform float g_ShadingDirection; // {"material":"ui_editor_properties_shading_direction","default":0,"range":[0,6.28]}
uniform vec3 g_Color1; // {"material":"ui_editor_properties_color_start","default":"1 1 1","type":"color"}
uniform vec3 g_Color2; // {"material":"ui_editor_properties_color_end","default":"0 0 0","type":"color"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	float cloud0 = texSample2D(g_Texture1, v_TexCoordClouds.xy).r;
	float cloud1 = texSample2D(g_Texture1, v_TexCoordClouds.zw).r;
	
	float cloudBlend = cloud0 * cloud1;
	vec3 cloudColor = CAST3(1.0);
	
#if SHADING == 1
	float light = 0.0;
	vec2 cloudDeltas = vec2(ddx(cloudBlend), ddy(cloudBlend));
	float shadingLength = length(cloudDeltas);
	if (shadingLength > 0.001)
	{
		cloudDeltas /= shadingLength;
		vec2 direction = rotateVec2(vec2(0, -1.0), g_ShadingDirection);
		light = dot(direction, cloudDeltas) * 0.5 + 0.5;
	}
	light = mix(0.5, light, g_CloudShading);
	cloudColor = mix(g_Color2, g_Color1, light);
#endif

	cloudBlend = smoothstep(g_CloudThreshold, g_CloudThreshold + g_CloudFeather, cloudBlend);
	
	float blend = cloudBlend * g_CloudsAlpha;
#if MASK == 1
	blend *= texSample2D(g_Texture2, v_TexCoord.zw).r;
#endif
	albedo.a = blend;
	
	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, cloudColor, blend);
	
#if BLENDMODE == 0
	albedo.a = 1.0;
#endif
	
	gl_FragColor = albedo;
}
