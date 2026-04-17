
// [COMBO] {"material":"ui_editor_properties_kernel_size","combo":"KERNEL","type":"options","default":0,"options":{"13x13":0,"7x7":1,"3x3":2}}

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":"1 1","linked":true,"range":[0.01, 2.0]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

#if KERNEL == 0
varying vec2 v_TexCoord[13];
#endif
#if KERNEL == 1
varying vec2 v_TexCoord[7];
#endif
#if KERNEL == 2
varying vec2 v_TexCoord[3];
#endif

uniform vec4 g_Texture0Resolution;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	
#if VERTICAL
	float offsetX = 0.0f;
	float offsetY = g_Scale.y / g_Texture0Resolution.w;
#else
	float offsetX = g_Scale.x / g_Texture0Resolution.z;
	float offsetY = 0.0f;
#endif
	
#if KERNEL == 0
	v_TexCoord[0] = vec2(a_TexCoord.x - offsetX * 6.0, a_TexCoord.y - offsetY * 6.0);
	v_TexCoord[1] = vec2(a_TexCoord.x - offsetX * 5.0, a_TexCoord.y - offsetY * 5.0);
	v_TexCoord[2] = vec2(a_TexCoord.x - offsetX * 4.0, a_TexCoord.y - offsetY * 4.0);
	v_TexCoord[3] = vec2(a_TexCoord.x - offsetX * 3.0, a_TexCoord.y - offsetY * 3.0);
	v_TexCoord[4] = vec2(a_TexCoord.x - offsetX * 2.0, a_TexCoord.y - offsetY * 2.0);
	v_TexCoord[5] = vec2(a_TexCoord.x - offsetX, a_TexCoord.y - offsetY);
	v_TexCoord[6] = vec2(a_TexCoord.x, a_TexCoord.y);
	v_TexCoord[7] = vec2(a_TexCoord.x + offsetX, a_TexCoord.y + offsetY);
	v_TexCoord[8] = vec2(a_TexCoord.x + offsetX * 2.0, a_TexCoord.y + offsetY * 2.0);
	v_TexCoord[9] = vec2(a_TexCoord.x + offsetX * 3.0, a_TexCoord.y + offsetY * 3.0);
	v_TexCoord[10] = vec2(a_TexCoord.x + offsetX * 4.0, a_TexCoord.y + offsetY * 4.0);
	v_TexCoord[11] = vec2(a_TexCoord.x + offsetX * 5.0, a_TexCoord.y + offsetY * 5.0);
	v_TexCoord[12] = vec2(a_TexCoord.x + offsetX * 6.0, a_TexCoord.y + offsetY * 6.0);
#endif
#if KERNEL == 1
	v_TexCoord[0] = vec2(a_TexCoord.x - offsetX * 3.0, a_TexCoord.y - offsetY * 3.0);
	v_TexCoord[1] = vec2(a_TexCoord.x - offsetX * 2.0, a_TexCoord.y - offsetY * 2.0);
	v_TexCoord[2] = vec2(a_TexCoord.x - offsetX, a_TexCoord.y - offsetY);
	v_TexCoord[3] = vec2(a_TexCoord.x, a_TexCoord.y);
	v_TexCoord[4] = vec2(a_TexCoord.x + offsetX, a_TexCoord.y + offsetY);
	v_TexCoord[5] = vec2(a_TexCoord.x + offsetX * 2.0, a_TexCoord.y + offsetY * 2.0);
	v_TexCoord[6] = vec2(a_TexCoord.x + offsetX * 3.0, a_TexCoord.y + offsetY * 3.0);
#endif
#if KERNEL == 2
	v_TexCoord[0] = vec2(a_TexCoord.x - offsetX, a_TexCoord.y - offsetY);
	v_TexCoord[1] = vec2(a_TexCoord.x, a_TexCoord.y);
	v_TexCoord[2] = vec2(a_TexCoord.x + offsetX, a_TexCoord.y + offsetY);
#endif
}
