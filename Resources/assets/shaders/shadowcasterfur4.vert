
// [COMBO] {"combo":"SKINNING"}
// [COMBO] {"combo":"MORPHING"}
// [COMBO] {"combo":"MORPHING_NORMALS"}
// [COMBO] {"combo":"BONECOUNT"}

#include "base/model_vertex_v1.h"

uniform mat4 g_ViewportViewProjectionMatrices[6];
in uint gl_InstanceID;
varying uint gl_ViewportIndex;

attribute vec3 a_Position;

#if MORPHING
uniform sampler2D g_Texture1; // {"material":"morph"}
uniform vec4 g_Texture1Texel;
#endif

void main() {
	vec3 localPos = a_Position;

#if MORPHING
	ApplyMorphPosition(gl_VertexID, MAKE_SAMPLER2D_ARGUMENT(g_Texture1), g_Texture1Texel, g_MorphOffsets, g_MorphWeights, localPos);
#endif

	vec4 worldPos;
#if SKINNING
	ApplySkinningPosition(localPos, a_BlendIndices, a_BlendWeights, worldPos);
#else
	ApplyPosition(localPos, worldPos);
#endif

	gl_Position = mul(worldPos, g_ViewportViewProjectionMatrices[gl_InstanceID]);
	gl_ViewportIndex = gl_InstanceID;
}
