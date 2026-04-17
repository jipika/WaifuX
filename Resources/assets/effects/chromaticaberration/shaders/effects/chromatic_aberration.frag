
// [COMBO] {"material":"ui_editor_properties_chroma","combo":"VARIATION","type":"options","default":0,"options":{"ui_editor_properties_chroma_red_blue":0,"ui_editor_properties_chroma_yellow_purple":1,"ui_editor_properties_chroma_magenta_green":2}}
// [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"ui_editor_properties_expansion":0,"ui_editor_properties_directional":1,"ui_editor_properties_radial":2,"ui_editor_properties_barrel":3}}

#include "common.h"

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float u_Direction; // {"material":"ui_editor_properties_direction","default":1.57079632679,"direction":true,"conversion":"rad2deg"}
uniform float u_Strength; // {"material":"ui_editor_properties_strength","default":1,"range":[0,2]}
uniform float u_CenterFalloff; // {"material":"ui_editor_properties_center_falloff","default":1,"range":[0,1]}
uniform vec2 u_Center; // {"material":"ui_editor_properties_center","position":true,"default":"0.5 0.5"}

varying vec4 v_TexCoord;

#if MODE == 3
vec2 BC(vec2 coords, in float amt)
{
	coords = coords * CAST2(2.0) - CAST2(1.0);
	float v = coords.x * coords.x + coords.y * coords.y;
	coords *= CAST2(1.0) + amt * v;
	coords = coords * CAST2(0.5) + CAST2(0.5);
	return coords;
}
#endif

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

#if MODE == 3
	vec2 refCoords = v_TexCoord.xy;
	
	refCoords -= CAST2(0.5);
	refCoords *= CAST2(1.0 - u_Strength * 0.0125);
	refCoords += CAST2(0.5);
	vec2 coords0 = BC(refCoords, u_Strength * 0.05);
	vec2 coords1 = BC(refCoords, u_Strength * -0.02);
#endif

	vec4 sc = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 s0 = texSample2D(g_Texture0, coords0);
	vec4 s1 = texSample2D(g_Texture0, coords1);
	
	vec4 albedo = sc;

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

#if MASK
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	albedo = mix(sc, albedo, mask);
#endif

	gl_FragColor = albedo;
}
