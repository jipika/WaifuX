
#include "common.h"

varying vec4 v_TexCoord;
varying vec2 v_Direction;

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"combo":"TIMEOFFSET","default":"util/black","label":"ui_editor_properties_time_offset","mode":"opacitymask"}
uniform float g_Time;

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":5,"range":[0.01,50],"group":"ui_editor_properties_wave"}
uniform float g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":200,"range":[0.01,1000],"group":"ui_editor_properties_wave"}
uniform float g_Exponent; // {"material":"exponent","label":"ui_editor_properties_exponent","default":1,"range":[0.51,4],"group":"ui_editor_properties_wave"}
uniform float g_Strength; // {"material":"strength","label":"ui_editor_properties_strength","default":0.1,"range":[0.01,1]}

#if DUALWAVES == 1
varying vec2 v_Direction2;

uniform float g_Speed2; // {"material":"speed2","label":"ui_editor_properties_speed","default":3,"range":[0.01,50],"group":"ui_editor_properties_wave_2"}
uniform float g_Scale2; // {"material":"scale2","label":"ui_editor_properties_scale","default":66,"range":[0.01,1000],"group":"ui_editor_properties_wave_2"}
uniform float g_Offset2; // {"material":"offset2","label":"ui_editor_properties_offset","default":0,"range":[-5,5],"group":"ui_editor_properties_wave_2"}
uniform float g_Exponent2; // {"material":"exponent2","label":"ui_editor_properties_exponent","default":1,"range":[0.51,4],"group":"ui_editor_properties_wave_2"}
#endif

void main() {
#if MASK
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1.0;
#endif

	vec2 texCoord = v_TexCoord.xy;
	vec2 texCoordMotion = texCoord;

#if PERSPECTIVE == 1
	texCoordMotion = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
#endif

	float pos = abs(dot((texCoordMotion - 0.5), v_Direction));
	float distance = g_Time * g_Speed + dot(texCoordMotion, v_Direction) * g_Scale;

#if DUALWAVES == 1
	float distance2 = (g_Time + g_Offset2) * g_Speed2 + dot(texCoordMotion, v_Direction2) * g_Scale2;
#endif

#if PERSPECTIVE == 1
	distance *= step(0.0, v_TexCoordPerspective.z);
#if DUALWAVES == 1
	distance2 *= step(0.0, v_TexCoordPerspective.z);
#endif
#endif

#if TIMEOFFSET
	float timeOffset = texSample2D(g_Texture2, v_TexCoord.zw).r * M_PI_2;
	distance += timeOffset;
#if DUALWAVES == 1
	distance2 += timeOffset;
#endif
#endif

	float strength = g_Strength * g_Strength;

	vec2 offset = vec2(v_Direction.y, -v_Direction.x);
	float val1 = sin(distance);
	float s1 = sign(val1);
	val1 = pow(abs(val1), g_Exponent);

#if DUALWAVES == 1
	vec2 offset2 = vec2(v_Direction2.y, -v_Direction2.x);
	float val2 = sin(distance2);
	float s2 = sign(val2);
	val2 = pow(abs(val2), g_Exponent2);

	texCoord += val1 * s1 * val2 * s2 * offset * strength * mask;
#else
	texCoord += val1 * s1 * offset * strength * mask;
#endif

	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
