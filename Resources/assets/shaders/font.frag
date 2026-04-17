
#include "common_fragment.h"

uniform vec4 g_Color4;

uniform sampler2D g_Texture0;

varying vec3 v_TexCoord;

void main() {
#if COLORFONT
	vec4 _sample = texSample2D(g_Texture0, v_TexCoord.xy);
	gl_FragColor = vec4(_sample.rgb * mix(CAST3(1.0), g_Color4.rgb, v_TexCoord.z), _sample.a * g_Color4.a);
#else
	float _sample = ConvertSampleR8(texSample2D(g_Texture0, v_TexCoord.xy));
	gl_FragColor = vec4(g_Color4.rgb, _sample * g_Color4.a);
#endif
}
