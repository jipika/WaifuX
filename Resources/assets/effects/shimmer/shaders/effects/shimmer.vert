
uniform mat4 g_ModelViewProjectionMatrix;

#if MASK
uniform vec4 g_Texture1Resolution;
#endif

#if OFFSET
uniform vec4 g_Texture2Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_TexCoord2;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xyzw = a_TexCoord.xyxy;
	v_TexCoord2.xy = a_TexCoord.xy;

#if MASK
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

#if OFFSET
	v_TexCoord2.xy = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
