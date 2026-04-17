
// [COMBO] {"material":"Blend mode","combo":"BLENDMODE","type":"imageblending","default":2}

#include "common_blending.h"

varying vec4 v_TexCoord;

uniform float g_Multiply; // {"material":"Multiply","default":1,"range":[0.0, 10.0]}

#if OPACITYMASK == 1
varying vec2 v_TexCoordOpacity;
#endif

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Blend texture","mode":"rgbmask","default":"util/white"}
uniform sampler2D g_Texture2; // {"material":"Opacity mask","mode":"opacitymask","default":"util/white","combo":"OPACITYMASK"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 mask = texSample2D(g_Texture1, v_TexCoord.zw);
	float blend = mask.a * g_Multiply;
	
#if OPACITYMASK == 1
	blend *= texSample2D(g_Texture2, v_TexCoordOpacity).r;
#endif

	albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, mask.rgb, blend);

	
	gl_FragColor = albedo;
}
