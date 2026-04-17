
uniform mat4 g_ModelViewProjectionMatrix;
uniform mat4 g_EffectTextureProjectionMatrixInverse;
uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;
uniform vec2 g_PointerPosition;

uniform float g_PointerScale; // {"material":"size","label":"ui_editor_properties_size","default":0.2,"range":[0.0, 1.0]}

#if OPACITYMASK == 1
uniform vec4 g_Texture3Resolution;

varying vec2 v_TexCoordOpacity;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

varying vec4 v_PointerUV;
varying float v_PointerScale;

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
	v_PointerUV.xyz = mul(vec4(pointer * 2 - 1, 0.0, 1.0), g_EffectTextureProjectionMatrixInverse).xyw;
	v_PointerUV.xy *= 0.5;
	v_PointerUV.w = g_Texture0Resolution.y / -g_Texture0Resolution.x;
	v_PointerScale = mix(999, 1.0 / g_PointerScale, step(0.001, g_PointerScale));
}
