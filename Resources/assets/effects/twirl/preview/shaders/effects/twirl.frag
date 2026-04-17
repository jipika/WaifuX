
// [COMBO] {"material":"ui_editor_properties_elliptical","combo":"ELLIPTICAL","type":"options","default":1}
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_repeat","combo":"REPEAT","type":"options","default":1}
// [COMBO] {"material":"ui_editor_properties_inner","combo":"INNER","type":"options","default":0}

#include "common.h"

varying vec2 v_TexCoord;
varying vec2 v_TexCoordMask;

uniform vec4 g_Texture0Resolution;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_noise","default":"util/noise"}

uniform vec2 g_SpinCenter; // {"material":"center","label":"ui_editor_properties_center","default":"0.5 0.5","position":true}
uniform float g_Size; // {"material":"size","label":"ui_editor_properties_size","default":0.5,"range":[0,1]}
uniform float g_Feather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.002,"range":[0,0.2]}

uniform float g_Amount; // {"material":"amount","label":"ui_editor_properties_amount","default":1.0,"range":[0,2.0]}
uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1.0,"range":[-5,5]}

uniform float g_Ratio; // {"material":"ratio","label":"ui_editor_properties_ratio","default":1.0,"range":[0,10]}
uniform float g_Axis; // {"material":"angle","label":"ui_editor_properties_angle","default":0.0,"range":[0,3.141]}

uniform float g_Time;
uniform float g_NoiseSpeed; // {"material":"noisespeed","label":"ui_editor_properties_noise_speed","default":0.15,"range":[0,0.2]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.5,"range":[0,1]}

void main() {
	
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	vec2 texCoord = v_TexCoord.xy;
	
	texCoord -= g_SpinCenter;
	texCoord.x *= aspect;
	
#if ELLIPTICAL
	texCoord.xy = rotateVec2(texCoord.xy, g_Axis);
	texCoord.x *= g_Ratio;
#endif

	float feather = smoothstep(g_Size + g_Feather + 0.00001, g_Size - g_Feather, length(texCoord.xy));
	
#if INNER
	float dist = (1.0 / length(texCoord)) * g_Size;
#else
	float dist = length(texCoord) / g_Size;
#endif

	float anim = sin(g_Time * g_Speed) * dist * g_Amount;
	
#if NOISE
	float noise = texSample2D(g_Texture2, vec2(g_Time * 0.08333333, g_Time * 0.02777777) * g_NoiseSpeed).r * 3.141 * 2.0;
	anim += sin(noise) * g_NoiseAmount;
#endif

	texCoord = rotateVec2(texCoord, anim);
	
#if ELLIPTICAL
	texCoord.x /= g_Ratio;
	texCoord.xy = rotateVec2(texCoord.xy, -g_Axis);
#endif

	texCoord.x /= aspect;
	texCoord += g_SpinCenter;

#if REPEAT
	texCoord = frac(texCoord);
#endif

	texCoord = mix(v_TexCoord.xy, texCoord, feather);

	gl_FragColor = texSample2D(g_Texture0, texCoord);
	
	float mask = 1.0;

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoordMask).r;
#endif

	gl_FragColor = mix(texSample2D(g_Texture0, v_TexCoord.xy), gl_FragColor, mask);
}
