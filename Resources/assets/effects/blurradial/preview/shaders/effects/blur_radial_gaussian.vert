
// [COMBO] {"material":"ui_editor_properties_kernel_size","combo":"KERNEL","type":"options","default":0,"options":{"13":0,"7":1,"3":2}}

uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

#if MASK
uniform vec4 g_Texture2Resolution;
varying vec2 v_TexCoordMask;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);

	v_TexCoord.xy = a_TexCoord;
#if MASK
	v_TexCoordMask.xy = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
