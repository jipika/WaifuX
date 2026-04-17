
// [COMBO_OFF] {"material":"ui_editor_properties_specular","combo":"SPECULAR","type":"options","default":0}

#include "common.h"

varying vec4 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_water_normal"}

uniform float g_Strength; // {"material":"ripplestrength","label":"ui_editor_properties_ripple_strength","default":0.1,"range":[0,1]}
uniform float g_SpecularPower; // {"material":"ripplespecularpower","label":"ui_editor_properties_ripple_specular_power","default":1.0,"range":[0,100]}
uniform float g_SpecularStrength; // {"material":"ripplespecularstrength","label":"ui_editor_properties_ripple_specular_strength","default":1.0,"range":[0,10]}
uniform vec3 g_SpecularColor; // {"material":"ripplespecularcolor","label":"ui_editor_properties_ripple_specular_color","default":"1 1 1","type":"color"}

#if PERSPECTIVE == 0
varying vec4 v_TexCoordRipple;
#else
uniform vec4 g_Texture0Resolution;
uniform float g_Time;
uniform float g_AnimationSpeed; // {"material":"animationspeed","label":"ui_editor_properties_animation_speed","default":0.15,"range":[0,0.5]}
uniform float g_Scale; // {"material":"scale","label":"ui_editor_properties_ripple_scale","default":1,"range":[0,10]}
uniform float g_ScrollSpeed; // {"material":"scrollspeed","label":"ui_editor_properties_scroll_speed","default":0,"range":[0,0.5]}
uniform float g_Direction; // {"material":"scrolldirection","label":"ui_editor_properties_scroll_direction","default":0,"direction":true,"conversion":"rad2deg"}
uniform float g_Ratio; // {"material":"ratio","label":"ui_editor_properties_ratio","default":1,"range":[0,10]}
varying vec3 v_TexCoordPerspective;
#endif

void main() {
	vec2 texCoord = v_TexCoord.xy;
	
#if MASK == 1
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
#else
	float mask = 1;
#endif

	vec4 rippleCoords;
	
#if PERSPECTIVE == 0
	rippleCoords = v_TexCoordRipple;
#else
	vec2 coordsRotated = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
	vec2 coordsRotated2 = coordsRotated * 1.333;
	
	vec2 scroll = rotateVec2(vec2(0, 1), g_Direction) * g_ScrollSpeed * g_ScrollSpeed * g_Time;
	
	rippleCoords.xy = coordsRotated + g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
	rippleCoords.zw = coordsRotated2 - g_Time * g_AnimationSpeed * g_AnimationSpeed + scroll;
	rippleCoords *= g_Scale;

	float rippleTextureAdjustment = (g_Texture0Resolution.x / g_Texture0Resolution.y);
	rippleCoords.xz *= rippleTextureAdjustment;
	rippleCoords.yw *= g_Ratio;
	
	mask *= step(0.0, v_TexCoordPerspective.z);
#endif
	
	vec3 n1 = texSample2D(g_Texture2, rippleCoords.xy).xyz * 2 - 1;
	vec3 n2 = texSample2D(g_Texture2, rippleCoords.zw).xyz * 2 - 1;
	vec3 normal = normalize(vec3(n1.xy + n2.xy, n1.z));
	
	texCoord.xy += normal.xy * g_Strength * g_Strength * mask;
	
	gl_FragColor = texSample2D(g_Texture0, texCoord);
	
#if SPECULAR == 1
	vec2 direction = vec2(0.5, 0.0) - v_TexCoord.xy;
	direction = normalize(direction);
	float specular = max(0.0, dot(normal.xy, direction)) * max(0.0, dot(direction, vec2(0.0, -1.0)));
	
	specular = pow(specular, g_SpecularPower) * g_SpecularStrength;
	gl_FragColor.rgb += specular * g_SpecularColor * gl_FragColor.a;
#endif
}
