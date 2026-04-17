
// [COMBO] {"material":"Blend mode","combo":"BLENDMODE","type":"imageblending","default":0}

#include "common.h"
#include "common_blending.h"

varying vec2 v_TexCoordKernel[9];

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_BlendAlpha; // {"material":"Alpha","default":1,"range":[0.01,1]}
uniform vec3 g_OutlineColor1; // {"material":"Outline color","default":"0 0 0","type":"color"}
uniform vec3 g_OutlineColor2; // {"material":"Outline background","default":"1 1 1","type":"color"}
uniform float g_DetectionThreshold; // {"material":"Detection threshold","default":0.5,"range":[0,5]}
uniform float g_DetectionMultiply; // {"material":"Detection multiply","default":1,"range":[0,5]}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoordKernel[4]);
	
	vec3 sample00 = texSample2D(g_Texture0, v_TexCoordKernel[0]).rgb;
	vec3 sample10 = texSample2D(g_Texture0, v_TexCoordKernel[1]).rgb;
	vec3 sample20 = texSample2D(g_Texture0, v_TexCoordKernel[2]).rgb;
	vec3 sample01 = texSample2D(g_Texture0, v_TexCoordKernel[3]).rgb;
	
	vec3 sample21 = texSample2D(g_Texture0, v_TexCoordKernel[5]).rgb;
	vec3 sample02 = texSample2D(g_Texture0, v_TexCoordKernel[6]).rgb;
	vec3 sample12 = texSample2D(g_Texture0, v_TexCoordKernel[7]).rgb;
	vec3 sample22 = texSample2D(g_Texture0, v_TexCoordKernel[8]).rgb;
	
	vec3 gx = sample20 - sample00 + (sample21 - sample01) * 2 + sample22 - sample02;
	vec3 gy = sample00 - sample02 + (sample10 - sample12) * 2 + sample20 - sample22;
	
	float g = abs(greyscale(gx)) + abs(greyscale(gy));
	
	vec3 combinedColor = mix(g_OutlineColor2, g_OutlineColor1,
							min(1.0, max(0.0, g - g_DetectionThreshold) * g_DetectionMultiply));
	
	gl_FragColor.a = albedo.a;
	gl_FragColor.rgb = ApplyBlending(BLENDMODE, albedo.rgb, combinedColor, g_BlendAlpha);
}
