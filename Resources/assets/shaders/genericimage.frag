
#include "common_fragment.h"

uniform sampler2D g_Texture0;

uniform float g_Brightness; // {"material":"Bright","default":1,"range":[0,2]}
uniform float g_UserAlpha; // {"material":"Alpha","default":1,"range":[0,1]}
uniform float g_Power; // {"material":"Power","default":1,"range":[0,6]}

varying vec2 v_TexCoord;

#if MULTI
uniform sampler2D g_Texture1;

varying vec2 v_TexCoord2;
#endif

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
#if MULTI
	albedo *= texSample2D(g_Texture1, v_TexCoord2.xy);
#endif
	
	albedo.rgb *= g_Brightness;
	albedo.a *= g_UserAlpha;
	albedo.rgb = pow(albedo.rgb, CAST3(g_Power));
	
	gl_FragColor = albedo;
}
