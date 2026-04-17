
// [COMBO] {"material":"ui_editor_properties_kernel_size","combo":"KERNEL","type":"options","default":0,"options":{"13x13":0,"7x7":1,"3x3":2}}

uniform mat4 g_ModelViewProjectionMatrix;
uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":"1 1","linked":true,"range":[0.01, 2.0]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

uniform vec4 g_Texture0Resolution;

#if MASK
uniform vec4 g_Texture2Resolution;
varying vec2 v_TexCoordMask;
#endif

void main() {
#if VERTICAL
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
#else
	gl_Position = vec4(a_Position, 1.0);
#endif
	
	v_TexCoord.xy = a_TexCoord;
	
#if VERTICAL
	v_TexCoord.z = 0;
	v_TexCoord.w = g_Scale.y / g_Texture0Resolution.w;
#else
	v_TexCoord.z = g_Scale.x / g_Texture0Resolution.z;
	v_TexCoord.w = 0;
#endif

#if MASK
	v_TexCoordMask.xy = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
