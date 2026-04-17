
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

uniform vec4 g_Texture0Resolution;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord.xy = a_TexCoord;

	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture0Resolution.z / g_Texture0Resolution.x,
						v_TexCoord.y * g_Texture0Resolution.w / g_Texture0Resolution.y);

#ifdef HLSL_SM30
	vec2 offsets = 0.5 / g_Texture0Resolution.xy;
	v_TexCoord.xy += offsets;
#endif
}
