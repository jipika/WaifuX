
#if MASK == 1
uniform vec4 g_Texture2Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord.xyzw = a_TexCoord.xyxy;
	
#if MASK == 1
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
