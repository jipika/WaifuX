
#include "base/model_vertex_v1.h"

uniform vec3 g_EyePosition;
uniform mat4 g_ViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec3 a_Normal;
attribute vec2 a_TexCoord;

varying vec3 v_WorldNormal;
varying vec4 v_ViewDir;
varying vec2 v_TexCoord;

varying vec3 v_LightAmbientColor;

#if LIGHTING || REFLECTION
#if NORMALMAP
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
#else
#endif
varying vec3 v_WorldPos;
#endif

varying vec3 v_ScreenPos;

#if MORPHING
uniform sampler2D g_Texture5; // {"material":"morph","hidden":true}
uniform vec4 g_Texture5Texel;
#endif

uniform sampler2D g_Texture0; // {"material":"albedo","label":"ui_editor_properties_albedo","default":"util/white"}

void main() {
	vec3 localPos = a_Position;
	vec3 localNormal = a_Normal;

#if MORPHING
	ApplyMorphPositionNormal(gl_VertexID, MAKE_SAMPLER2D_ARGUMENT(g_Texture5), g_Texture5Texel, g_MorphOffsets, g_MorphWeights, localPos, localNormal);
#endif

	vec4 worldPos;
	vec3 worldNormal;

#if SKINNING
	ApplySkinningPositionNormal(localPos, localNormal, a_BlendIndices, a_BlendWeights, worldPos, worldNormal);
#else
	ApplyPositionNormal(localPos, localNormal, worldPos, worldNormal);
#endif

	gl_Position = mul(worldPos, g_ViewProjectionMatrix);

	v_TexCoord.xy = a_TexCoord;
	v_ViewDir.xyz = g_EyePosition - worldPos.xyz;
	v_ViewDir.w = worldPos.y;

#if LIGHTING || REFLECTION
	v_WorldPos = worldPos.xyz;
#endif

#if NORMALMAP
	mat3 tangentSpace;
#if SKINNING
	ApplySkinningTangentSpace(worldNormal, a_Tangent4, a_BlendIndices, a_BlendWeights, tangentSpace);
#else
	ApplyTangentSpace(worldNormal, a_Tangent4, tangentSpace);
#endif

	v_Tangent = tangentSpace[0];
	v_Bitangent = tangentSpace[1];
	v_Normal = tangentSpace[2];
#endif

	v_WorldNormal.xyz = worldNormal;

	ClipSpaceToScreenSpace(gl_Position, v_ScreenPos);

	v_LightAmbientColor = ApplyAmbientLighting(worldNormal);
}
