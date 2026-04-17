
#include "common_fragment.h"

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
uniform sampler2D g_Texture2;

#if TINT
uniform vec3 g_Color1; // {"material":"color1","default":"0 0 0"}
uniform vec3 g_Color2; // {"material":"color2","default":"0 0 0"}
uniform vec3 g_Color3; // {"material":"color3","default":"1 1 1"}
#endif

uniform float g_WaveStrength; // {"material":"Strength","default":0.5}

varying vec2 v_TexCoord;
varying vec4 v_NormalCoord;

void main() {
	vec2 normalCoords1 = v_NormalCoord.xy;
	vec2 normalCoords2 = v_NormalCoord.zw;
		
	normalCoords1.x -= ((0.5 - v_TexCoord.x) * (1 - v_TexCoord.y)) * 3;
	normalCoords1.x += 2 * pow(v_TexCoord.y - 0.1, 3) * pow(v_TexCoord.x, 2);
	normalCoords2.x -= ((1.0 - v_TexCoord.x) * (1 - v_TexCoord.y)) * 2;
	
	vec3 normal = DecompressNormal(texSample2D(g_Texture1, normalCoords1));
	normal *= DecompressNormal(texSample2D(g_Texture1, normalCoords2));
	//normal.xy += DecompressNormal(texSample2D(g_Texture1, normalCoords2)).xy;
	
	normal = mix(vec3(0, 0, 1), normal, g_WaveStrength);
	normal = normalize(normal);
	
	vec2 baseCoords = v_TexCoord.xy + normal.xy * 0.02;

	//vec2 baseCoords2 = v_TexCoord.xy + normal.xy * 0.1;
	//clip(baseCoords2.y - 0.1);
	//clip(0.9 - baseCoords2.y);
	//clip(baseCoords2.x - 0.18);
	//clip(0.82 - baseCoords2.x);

	vec3 albedo = texSample2D(g_Texture0, baseCoords.xy).rgb;
	float cloth = texSample2D(g_Texture2, baseCoords.xy * 4).r;
	
#if TINT
	vec3 color = mix(g_Color1, g_Color2, albedo.r);
	color = mix(color, g_Color3, albedo.g);
	color *= albedo.b * cloth;
	color += cloth * 0.1;
#else
	vec3 color = albedo;
#endif
	
	float light = 0.2 + dot(vec3(0.707, 0.707, 0), normal) * 0.5 + 0.5;
	light += pow(light, 5) * 0.5;
	color *= light + light * saturate(cloth * 2 - 1);
	
	// Vignette
	//float vignette = length(v_TexCoord.xy - 0.5);
	//color *= smoothstep(0.7, 0.2, vignette);
	
	// gl_FragColor = albedo;
	gl_FragColor.rgb = color;
	gl_FragColor.a = 1;
	
	//gl_FragColor.rgb = (normal * 0.5 + 0.5);
}
