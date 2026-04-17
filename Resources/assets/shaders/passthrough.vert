
uniform mat4 g_ModelViewProjectionMatrix;

#if SPRITESHEET
uniform vec4 g_Texture0Rotation;
uniform vec2 g_Texture0Translation;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

void main() {
#ifdef TRANSFORM
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
#else
	gl_Position = vec4(a_Position, 1.0);
#endif

#if SPRITESHEET
	v_TexCoord.xy = g_Texture0Translation + a_TexCoord.x * g_Texture0Rotation.xy + a_TexCoord.y * g_Texture0Rotation.zw;
#else
	v_TexCoord.xy = a_TexCoord;
#endif
}
