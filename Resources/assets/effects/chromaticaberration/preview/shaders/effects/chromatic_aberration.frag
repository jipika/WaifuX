
// [COMBO] {"material":"ui_editor_properties_chroma","combo":"VARIATION","type":"options","default":0,"options":{"Red, blue":0,"Yellow, purple":1,"Magenta, green":2}}
// [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"Expansion":0,"Directional":1,"Radial":2}}

#include "common.h"

uniform sampler2D g_Texture0; // {"hidden":true}

uniform float u_Direction; // {"material":"ui_editor_properties_direction","default":1.57079632679,"direction":true,"conversion":"rad2deg"}
uniform float u_Strength; // {"material":"ui_editor_properties_strength","default":1,"range":[0,2]}
uniform float u_CenterFalloff; // {"material":"ui_editor_properties_center_falloff","default":1,"range":[0,1]}
uniform vec2 u_Center; // {"material":"ui_editor_properties_center","position":true,"default":"0.5 0.5"}

varying vec2 v_TexCoord;

void main() {
	vec2 delta = v_TexCoord.xy - u_Center;

#if MODE == 0
	float falloff = mix(0.5 / (length(delta) + 0.0001), 1.0, u_CenterFalloff);
	delta *= u_Strength * 0.01 * falloff;
	vec2 coords0 = v_TexCoord.xy + delta;
	vec2 coords1 = v_TexCoord.xy - delta;
#endif

#if MODE == 1
	vec2 direction = vec2(-sin(u_Direction), cos(u_Direction));
	float falloff = mix(1.0, abs(dot(direction, delta)) * 2.0, u_CenterFalloff);
	direction *= u_Strength * 0.01 * falloff;
	vec2 coords0 = v_TexCoord.xy + direction;
	vec2 coords1 = v_TexCoord.xy - direction;
#endif

#if MODE == 2
	float falloff = mix(0.5 / (length(delta) + 0.0001), 1.0, u_CenterFalloff);
	float amt = u_Strength * 0.01 * falloff;
	vec2 coords0 = u_Center + rotateVec2(delta, amt);
	vec2 coords1 = u_Center + rotateVec2(delta, -amt);
#endif

	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	vec4 s0 = texSample2D(g_Texture0, coords0);
	vec4 s1 = texSample2D(g_Texture0, coords1);

#if VARIATION == 0
	albedo.r = s0.r;
	albedo.b = s1.b;
#endif

#if VARIATION == 1
	albedo.g = s1.g;
	albedo.b = s0.b;
#endif

#if VARIATION == 2
	albedo.g = s0.g;
	albedo.r = s1.r;
#endif

	gl_FragColor = albedo;
}
