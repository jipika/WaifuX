
// [COMBO] {"combo":"SKINNING"}
// [COMBO] {"combo":"MORPHING"}
// [COMBO] {"combo":"MORPHING_NORMALS"}
// [COMBO] {"combo":"BONECOUNT"}
// [COMBO] {"combo":"LEAVESUVMODE"}

#include "base/model_vertex_v1.h"
#include "common_foliage.h"

uniform mat4 g_ViewportViewProjectionMatrices[6];
in uint gl_InstanceID;
varying uint gl_ViewportIndex;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

#if MORPHING
uniform sampler2D g_Texture1; // {"material":"morph"}
uniform vec4 g_Texture1Resolution;
#endif

#if ALPHATOCOVERAGE
varying vec2 v_TexCoord;
#endif

uniform float g_Time;
uniform float g_SpeedLeaves; // {"material":"foliagespeedleaves"}
uniform float g_SpeedBase; // {"material":"foliagespeedbase"}
uniform float g_StrengthLeaves; // {"material":"strengthleaves"}
uniform float g_StrengthBase; // {"material":"strengthbase"}
uniform float g_Phase; // {"material":"foliagephase"}
uniform float g_FoliageScale; // {"material":"foliagescale"}
uniform float g_Direction; // {"material":"scrolldirection"}
uniform float g_CutOff; // {"material":"foliagecutoff"}
uniform float g_TreeHeight; // {"material":"foliageheight"}
uniform float g_TreeRadius; // {"material":"foliageradius"}
uniform vec2 g_FoliageUVBounds; // {"material":"foliageuvbounds"}

void main() {
#if ALPHATOCOVERAGE
	v_TexCoord = a_TexCoord;
#endif

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

#if LEAVESUVMODE
	vec2 leafUVs = a_TexCoord;
#else
	vec2 leafUVs = CAST2(1);
#endif

	worldPos.xyz += CalcFoliageAnimation(worldPos.xyz, localPos, leafUVs, g_Direction, g_Time,
		g_SpeedLeaves, g_SpeedBase, g_StrengthLeaves, g_StrengthBase,
		g_Phase, g_FoliageScale, g_CutOff, g_TreeHeight, g_TreeRadius, g_FoliageUVBounds);

	gl_Position = mul(worldPos, g_ViewportViewProjectionMatrices[gl_InstanceID]);
	gl_ViewportIndex = gl_InstanceID;
}
