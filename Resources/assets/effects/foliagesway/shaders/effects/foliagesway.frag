
// [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}

#include "common.h"

uniform sampler2D g_Texture0; // {"hidden":true}

#if MODE == 0
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_noise","default":"util/noise"}

varying vec4 v_TexCoordNoise;
varying vec3 v_Params;
#endif

uniform float g_Speed; // {"material":"speeduv","label":"ui_editor_properties_speed","default":5,"range":[0.01, 20]}
uniform float g_Power; // {"material":"power","label":"ui_editor_properties_power","default":1,"range":[0.01, 2]}
uniform float g_Phase; // {"material":"phase","label":"ui_editor_properties_phase","default":0.5,"range":[0, 2]}

uniform float g_Time;

varying vec4 v_TexCoord;

void main() {
#if !MODE
	vec3 noise = texSample2D(g_Texture2, v_TexCoordNoise.xy).rgb;
	
	float amp = v_Params.z; //g_Strength * 0.01;
#if MASK
	amp *= texSample2D(g_Texture1, v_TexCoord.zw).r;
#endif
	
	float phase = (noise.g * M_PI * 2 + v_Params.x * 10 + v_Params.y * 5) * g_Phase;
	vec4 sines = phase + g_Speed * g_Time * vec4(1, -0.16161616, 0.0083333, -0.00019841);
	sines = sin(sines);
	vec4 csines = 0.4 + phase + g_Speed * g_Time * vec4(-0.5, 0.041666666, -0.0013888889, 0.000024801587);
	csines = sin(csines);
	
	sines = pow(abs(sines), CAST4(g_Power)) * sign(sines);
	csines = pow(abs(csines), CAST4(g_Power)) * sign(csines);
	
	
	vec2 texCoordOffset;
	texCoordOffset.x = v_TexCoordNoise.z * dot(sines, CAST4(amp));
	texCoordOffset.y = v_TexCoordNoise.w * dot(csines, CAST4(amp));
	gl_FragColor = texSample2D(g_Texture0, texCoordOffset + v_TexCoord.xy);

#else
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy);
#endif
}
