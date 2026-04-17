
// [COMBO] {"material":"ui_editor_properties_kernel_size","combo":"KERNEL","type":"options","default":1,"options":{"13x13":0,"7x7":1,"3x3":2}}

uniform vec2 g_Scale; // {"material":"blurscale","label":"ui_editor_properties_blur_scale","default":"1 1","linked":true,"range":[0.01, 2.0]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

uniform vec4 g_Texture0Resolution;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
	v_TexCoord.xy = a_TexCoord;
	
#if VERTICAL
	v_TexCoord.z = 0;
	v_TexCoord.w = g_Scale.y / g_Texture0Resolution.w;
#else
	v_TexCoord.z = g_Scale.x / g_Texture0Resolution.z;
	v_TexCoord.w = 0;
#endif
}
