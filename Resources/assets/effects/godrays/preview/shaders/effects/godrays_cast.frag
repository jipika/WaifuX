
// [COMBO] {"material":"Caster","combo":"CASTER","type":"options","default":0,"options":{"Radial":0,"Directional":1}}

#include "common.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_Length; // {"material":"Ray length","default":0.5,"range":[0.01, 1]}
uniform float g_Intensity; // {"material":"Ray intensity","default":1,"range":[0.01, 2.0]}
uniform vec3 g_Color1; // {"material":"Color start","default":"1 1 1","type":"color"}
uniform vec3 g_Color2; // {"material":"Color end","default":"1 1 1","type":"color"}

#if CASTER == 0
uniform vec2 g_Center; // {"material":"Center","default":"0.5 0.5"}
#else
uniform float g_Direction; // {"material":"Direction","default":0,"range":[0,6.28]}
#endif

void main() {

	vec2 texCoords = v_TexCoord;
	vec4 albedo = CAST4(0.0);
	
#if CASTER == 0
	vec2 direction = g_Center - texCoords;
#else
	vec2 direction = rotateVec2(vec2(0, -0.5), g_Direction);
#endif
	
	float dist = length(direction);
	direction /= dist;
	
	dist = min(dist, dist * g_Length);
	texCoords += direction * dist;
	direction = direction * dist / 29.0;
	
	for (int i = 0; i < 30; ++i)
	{
		vec4 sample = texSample2D(g_Texture0, texCoords);
		texCoords -= direction;
		sample.rgb *= mix(g_Color2, g_Color1, i/29.0);
		albedo += sample * (i / 29.0);
	}

	gl_FragColor = albedo * g_Intensity * 0.1;
}
