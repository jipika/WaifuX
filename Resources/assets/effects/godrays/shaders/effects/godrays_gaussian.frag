
uniform sampler2D g_Texture0; // {"hidden":true}

#include "common_blur.h"

varying vec4 v_TexCoord;

void main() {
#if KERNEL == 0
	gl_FragColor = blur13a(v_TexCoord.xy, v_TexCoord.zw);
#endif
#if KERNEL == 1
	gl_FragColor = blur7a(v_TexCoord.xy, v_TexCoord.zw);
#endif
#if KERNEL == 2
	gl_FragColor = blur3a(v_TexCoord.xy, v_TexCoord.zw);
#endif
}
