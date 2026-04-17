
// [COMBO] {"material":"Background","combo":"BACKGROUND","type":"options","default":1}

#include "common.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_Size; // {"material":"Size","default":1,"range":[0.01, 1]}
uniform float g_Scale; // {"material":"Distortion","default":1,"range":[0, 2.5]}
uniform vec2 g_Center; // {"material":"Center","default":"0.5 0.5"}

void main() {
	//vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	float aperture = 178.0;
	float apertureHalf = 0.5 * aperture * (M_PI / 180.0);
	float maxFactor = sin(apertureHalf);

	vec2 uv;
	vec2 xy = (v_TexCoord.xy - g_Center) * 2.0 / g_Size;
	float d = length(xy);
	float alpha = 1.0;
	if (d < (2.0 - maxFactor))
	{
		d = length(xy * maxFactor);
		float z = sqrt(1.0 - d * d);
		float r = atan2(d, z) / M_PI;
		float phi = atan2(xy.y, xy.x);

		uv.x = r * cos(phi) * g_Size + g_Center.x;
		uv.y = r * sin(phi) * g_Size + g_Center.y;
	}
	else
	{
		uv = v_TexCoord.xy;
#if BACKGROUND == 0
		alpha = 0.0;
#endif
	}
	
	vec4 albedo = texSample2D(g_Texture0, mix(v_TexCoord.xy, uv, g_Scale));
	albedo.a *= alpha;
	gl_FragColor = albedo;
}
