
#include "common.h"

uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_TextureReductionScale;
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

#if NUMBLENDTEXTURES >= 2
varying vec4 v_TexCoord23;
#endif
#if NUMBLENDTEXTURES >= 4
varying vec4 v_TexCoord45;
#endif
#if NUMBLENDTEXTURES >= 6
varying vec2 v_TexCoord6;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#if NUMBLENDTEXTURES >= 2
	v_TexCoord23.xy = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
	v_TexCoord23.zw = CAST2(0.0);
#endif
#if NUMBLENDTEXTURES >= 3
	v_TexCoord23.zw = vec2(v_TexCoord.x * g_Texture3Resolution.z / g_Texture3Resolution.x,
						v_TexCoord.y * g_Texture3Resolution.w / g_Texture3Resolution.y);
#endif
#if NUMBLENDTEXTURES >= 4
	v_TexCoord45.xy = vec2(v_TexCoord.x * g_Texture4Resolution.z / g_Texture4Resolution.x,
						v_TexCoord.y * g_Texture4Resolution.w / g_Texture4Resolution.y);
	v_TexCoord45.zw = CAST2(0.0);
#endif
#if NUMBLENDTEXTURES >= 5
	v_TexCoord45.zw = vec2(v_TexCoord.x * g_Texture5Resolution.z / g_Texture5Resolution.x,
						v_TexCoord.y * g_Texture5Resolution.w / g_Texture5Resolution.y);
#endif
#if NUMBLENDTEXTURES >= 6
	v_TexCoord6.xy = vec2(v_TexCoord.x * g_Texture6Resolution.z / g_Texture6Resolution.x,
						v_TexCoord.y * g_Texture6Resolution.w / g_Texture6Resolution.y);
#endif

#if TRANSFORMUV == 1
	vec2 scaleA = g_Texture0Resolution.zw / g_Texture1Resolution.zw;
	//vec2 scaleB = g_Texture0Resolution.wz / g_Texture1Resolution.wz;
	//vec2 dir = abs(rotateVec2(vec2(1, 0), g_BlendAngle));
	
	v_TexCoord.zw -= ((g_BlendOffset / g_TextureReductionScale) - (g_Texture0Resolution.zw - g_Texture1Resolution.zw) * 0.5) / g_Texture0Resolution.zw;
	
	v_TexCoord.zw -= CAST2(0.5);
	v_TexCoord.zw = rotateVec2(v_TexCoord.zw, g_BlendAngle);
	// Too tired now to get this right, maybe look later at this again
	//v_TexCoord.zw *= scaleA * dot(dir, vec2(1, 0)) + scaleB * dot(dir, vec2(0, 1));
	//v_TexCoord.zw *= mix(scaleA, scaleB, abs(sin(g_BlendAngle))) / g_BlendScale;
	v_TexCoord.zw *= scaleA / g_BlendScale;
	//v_TexCoord.zw *= scaleA * abs(cos(g_BlendAngle)) + scaleB * abs(sin(g_BlendAngle));
	
	v_TexCoord.zw += CAST2(0.5);
#endif

#if OPACITYMASK == 1
	v_TexCoordOpacity = vec2(v_TexCoord.x * g_Texture7Resolution.z / g_Texture7Resolution.x,
						v_TexCoord.y * g_Texture7Resolution.w / g_Texture7Resolution.y);
#endif
}
