
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

#if OPACITYMASK == 1
uniform vec4 g_Texture3Resolution;

varying vec2 v_TexCoordOpacity;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

uniform mat4 g_ModelViewProjectionMatrixInverse;

uniform vec4 g_Texture0Resolution;
uniform vec2 g_PointerPosition;

varying vec3 v_PointerUV;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
						
#if OPACITYMASK == 1
	v_TexCoordOpacity = vec2(v_TexCoord.x * g_Texture3Resolution.z / g_Texture3Resolution.x,
						v_TexCoord.y * g_Texture3Resolution.w / g_Texture3Resolution.y);
#endif

	vec2 pointer = g_PointerPosition;
	pointer.y = 1.0 - pointer.y; // Flip pointer screen space Y to match texture space Y
	v_PointerUV = mul(vec4(pointer * 2 - 1, 0.0, 1.0), g_ModelViewProjectionMatrixInverse).xyw;
	v_PointerUV.xy *= 1.0 / g_Texture0Resolution.xy;
}
