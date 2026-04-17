
#include "common.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;

#if LUT
uniform sampler3D g_Texture1;
#endif

uniform vec4 g_Params; // {"material":"params","default":"1 1 1 0"}
uniform float g_LutParams; // {"material":"lutparams","default":1}

void main()
{
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);

#if COL
	albedo.rgb = mix(CAST3(0.5), albedo.rgb, g_Params.y);
	
	vec3 hsv = rgb2hsv(albedo.xyz);
	hsv.z *= g_Params.x;
	hsv.y *= g_Params.z;
	hsv.x += g_Params.w;
	albedo.rgb = hsv2rgb(hsv);
#endif

#if LUT
#if HDR
	vec3 overbright = max(CAST3(0), albedo.rgb - CAST3(1.0));
	vec3 albedoFiltered = texSample3D(g_Texture1, albedo.rgb);
	vec3 lutColor = albedoFiltered * (1 + dot(overbright, CAST3(1.0)));
#else
	vec3 albedoFiltered = texSample3D(g_Texture1, albedo.rgb);
	vec3 lutColor = albedoFiltered;
#endif
	albedo.rgb = mix(albedo.rgb, lutColor, g_LutParams);
#endif

	gl_FragColor = albedo;
}
