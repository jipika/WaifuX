
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_EffectModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);

	v_TexCoord = a_TexCoord;
	v_ScreenCoord = mul(vec4((a_Position), 1.0), g_EffectModelViewProjectionMatrix).xyw;
#if HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif
}
