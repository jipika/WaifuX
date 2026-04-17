
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if COPYBG
uniform mat4 g_EffectModelViewProjectionMatrix;

varying vec3 v_ScreenCoord;
#endif

#ifdef HLSL_SM30
uniform vec4 g_Texture0Resolution;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	
	v_TexCoord = a_TexCoord.xyxy;
	
#ifdef HLSL_SM30
	v_TexCoord.zw += 0.5 / g_Texture0Resolution.xy;
#endif

#if COPYBG
	v_ScreenCoord = mul(vec4((a_Position), 1.0), g_EffectModelViewProjectionMatrix).xyw;
#if HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif
#endif
}
