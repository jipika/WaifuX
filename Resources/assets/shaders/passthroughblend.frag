
#include "common_blending.h"

varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	
#if BLENDMODE == 0
	gl_FragColor = albedo;
#else
	vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5;
	vec4 screen = texSample2D(g_Texture1, screenCoord);
	
	gl_FragColor.rgb = ApplyBlending(BLENDMODE, screen.rgb, albedo.rgb, albedo.a);
	gl_FragColor.a = screen.a;
#endif
}
