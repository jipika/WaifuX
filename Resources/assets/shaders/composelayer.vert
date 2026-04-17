
uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

void main() {
	v_ScreenCoord = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix).xyw;
	vec3 position = vec3(a_TexCoord, 0.0);
	
#ifdef HLSL
	position.y = 1.0 - position.y;
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif
	
	position.xy = position.xy * 2.0 - 1.0;
	gl_Position = vec4(position, 1.0);
	
	v_TexCoord = a_TexCoord;
}
