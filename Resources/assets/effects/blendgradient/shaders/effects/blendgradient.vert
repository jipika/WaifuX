
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;
uniform vec4 g_Texture2Resolution;
uniform vec4 g_Texture3Resolution;
uniform vec4 g_Texture4Resolution;
uniform vec4 g_Texture5Resolution;
uniform vec4 g_Texture6Resolution;

#if OPACITYMASK == 1
uniform vec4 g_Texture7Resolution;

varying vec2 v_TexCoordOpacity;
#endif

#if TRANSFORMUV == 1
uniform vec4 g_Texture0Resolution;
#endif

uniform vec2 g_BlendOffset; // {"material":"blendoffset","label":"ui_editor_properties_offset","default":"0 0"}
uniform float g_BlendAngle; // {"material":"blendangle","label":"ui_editor_properties_angle","default":0,"range":[0,6.28]}
uniform float g_BlendScale; // {"material":"blendscale","label":"ui_editor_properties_scale","default":1,"range":[0.01,2]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);

#if TRANSFORMUV == 1
	vec2 scaleA = g_Texture0Resolution.zw / g_Texture1Resolution.zw;
	
	v_TexCoord.zw -= (g_BlendOffset - (g_Texture0Resolution.zw - g_Texture1Resolution.zw) * 0.5) / g_Texture0Resolution.zw;
	
	v_TexCoord.zw -= CAST2(0.5);
	v_TexCoord.zw = rotateVec2(v_TexCoord.zw, g_BlendAngle);
	v_TexCoord.zw *= scaleA / g_BlendScale;
	v_TexCoord.zw += CAST2(0.5);
#endif

#if OPACITYMASK == 1
	v_TexCoordOpacity = vec2(v_TexCoord.x * g_Texture7Resolution.z / g_Texture7Resolution.x,
						v_TexCoord.y * g_Texture7Resolution.w / g_Texture7Resolution.y);
#endif
}
