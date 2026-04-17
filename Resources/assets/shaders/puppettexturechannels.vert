
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_BlendMap[BLENDROWCOUNT];
uniform vec4 g_Texture1Resolution;

attribute vec3 a_Position;
attribute vec4 a_TexCoordVec4;
attribute uvec4 a_BlendIndices;

varying vec3 v_TexCoordBlend;
varying vec2 v_TexCoordBase;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoordBlend.xy = a_TexCoordVec4.xy;
	v_TexCoordBase.xy = a_TexCoordVec4.zw * (g_Texture1Resolution.zw / g_Texture1Resolution.xy);
#ifdef GLSL
	v_TexCoordBlend.z = g_BlendMap[int(floor(float(a_BlendIndices.x) / 4.0))][int(mod(float(a_BlendIndices.x), 4.0))];
#else
	v_TexCoordBlend.z = g_BlendMap[a_BlendIndices.x / 4.0][mod(a_BlendIndices.x, 4.0)];
#endif
}
