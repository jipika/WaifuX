
#include "common_blur.h"

varying vec4 v_TexCoord;
uniform sampler2D g_Texture0;

void main() {
#if VERTICAL
	vec3 albedo = blur3(v_TexCoord.xy, vec2(0, v_TexCoord.w));
#else
	vec3 albedo = blur3(v_TexCoord.xy, vec2(v_TexCoord.z, 0));
#endif
	gl_FragColor = vec4(albedo, 1.0);
}
