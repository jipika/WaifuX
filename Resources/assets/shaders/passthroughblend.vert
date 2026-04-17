
uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

#if SKINNING
uniform mat4x3 g_Bones[BONECOUNT];
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
#endif

void main() {

#if SKINNING
	vec3 localPos = mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices[0]]) * a_BlendWeights[0] +
					mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices[1]]) * a_BlendWeights[1] +
					mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices[2]]) * a_BlendWeights[2] +
					mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices[3]]) * a_BlendWeights[3];
#else
	vec3 localPos = a_Position;
#endif

#ifdef TRANSFORM
	gl_Position = mul(vec4(localPos, 1.0), g_ModelViewProjectionMatrix);
	v_ScreenCoord = gl_Position.xyw;
#else
	gl_Position = vec4(localPos, 1.0);
	v_ScreenCoord = mul(vec4(localPos, 1.0), g_ModelViewProjectionMatrix).xyw;
#endif

#ifdef HLSL
	v_ScreenCoord.y = -v_ScreenCoord.y;
#endif

	v_TexCoord = a_TexCoord;
}
