
// [COMBO] {"material":"ui_editor_properties_shading","combo":"SHADING","type":"options","default":0}

#include "common.h"

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
//uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

//uniform vec4 g_Texture0Resolution;

uniform float g_RippleStrength; // {"material":"ripplestrength","label":"ui_editor_properties_ripple_strength","default":1.0,"range":[0,5]}
uniform float g_ShadingAmount; // {"material":"shadingamount","label":"ui_editor_properties_shading_amount","default":1.0,"range":[0,2]}
uniform vec3 g_ShadingHigh; // {"material":"shadingtinthigh","label":"ui_editor_properties_tint_high","type":"color","default":"1 1 1"}
uniform vec3 g_ShadingLow; // {"material":"shadingtintlow","label":"ui_editor_properties_tint_low","type":"color","default":"0 0 0"}
uniform float g_ShadingDirection; // {"material":"shadingdirection","label":"ui_editor_properties_shading_direction","default":0,"range":[0,6.28],"direction":true,"conversion":"rad2deg"}

varying vec2 v_TexCoord;

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

void main() {

	vec2 srcCoords = v_TexCoord.xy;
	vec2 rippleCoords = v_TexCoord.xy;
	float rippleMask = 1.0;
	
#if PERSPECTIVE == 1
	rippleCoords = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
	rippleMask *= step(abs(rippleCoords.x - 0.5), 0.5);
	rippleMask *= step(abs(rippleCoords.y - 0.5), 0.5);
#endif

	vec4 albedo = texSample2D(g_Texture0, rippleCoords);
	albedo *= albedo;
	
	vec2 dir = vec2(albedo.x - albedo.z, albedo.y - albedo.w);
	
	//float pi = 3.14159265359;
	float distortAmt = g_RippleStrength;
	//distortAmt *= length(dir) * 1.0 * abs(sin(2.0 * atan2(dir.x, dir.y)));
	
	vec2 offset = dir;
	offset *= -0.1 * distortAmt * rippleMask;
	//offset.y = 0;
	//offset.x = 0;

	vec4 screen = texSample2D(g_Texture1, srcCoords + offset);
	//vec4 albedoOld = texSample2D(g_Texture2, v_TexCoord.xy);
	
#if SHADING
	vec2 shadingDir = dir;
	float shadingLength = max(0.99, length(shadingDir));
	shadingDir = mix(shadingDir, shadingDir / shadingLength, step(1.0, shadingLength));
	float shading = dot(rotateVec2(vec2(0, -1), g_ShadingDirection), shadingDir);
	
	screen.rgb = mix(screen.rgb, screen.rgb * mix(g_ShadingLow, CAST3(1.0) + g_ShadingHigh, shading * 0.5 + 0.5), abs(shading * g_ShadingAmount) * rippleMask);
#endif
	
	gl_FragColor = screen;
	
	
	//vec4 dirColorTest = vec4(dir * 0.5 + 0.5, 0.0, 1.0);
	//gl_FragColor = dirColorTest;
	
	//gl_FragColor += vec4(distortAmt, distortAmt, distortAmt, 1);
}
