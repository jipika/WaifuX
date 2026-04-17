
#include "base/model_vertex_v1.h"
#include "common_foliage.h"

uniform vec3 g_EyePosition;
uniform mat4 g_ViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec3 a_Normal;
attribute vec2 a_TexCoord;

varying vec4 v_ViewDir;
varying vec2 v_TexCoord;

varying vec3 v_LightAmbientColor;

#if LIGHTING || REFLECTION
#if NORMALMAP
varying vec3 v_Normal;
varying vec3 v_Tangent;
varying vec3 v_Bitangent;
#else
varying vec3 v_WorldNormal;
#endif
varying vec3 v_WorldPos;
#endif

#if REFLECTION
varying vec3 v_ScreenPos;
#endif

#if MORPHING
uniform sampler2D g_Texture5; // {"material":"morph","hidden":true}
uniform vec4 g_Texture5Texel;
#endif

uniform float g_Time;
uniform float g_SpeedLeaves; // {"material":"foliagespeedleaves","label":"ui_editor_properties_speed_leaves","default":5,"range":[0.01, 10],"group":"ui_editor_properties_foliage"}
uniform float g_SpeedBase; // {"material":"foliagespeedbase","label":"ui_editor_properties_speed_base","default":1,"range":[0.01, 10],"group":"ui_editor_properties_foliage"}
uniform float g_StrengthLeaves; // {"material":"strengthleaves","label":"ui_editor_properties_strength_leaves","default":0.015,"range":[0, 0.1],"group":"ui_editor_properties_foliage"}
uniform float g_StrengthBase; // {"material":"strengthbase","label":"ui_editor_properties_strength_base","default":0.04,"range":[0, 0.2],"group":"ui_editor_properties_foliage"}
uniform float g_Phase; // {"material":"foliagephase","label":"ui_editor_properties_phase","default":0,"range":[0, 6.28],"group":"ui_editor_properties_foliage"}
uniform float g_FoliageScale; // {"material":"foliagescale","label":"ui_editor_properties_scale","default":3,"range":[0, 10],"group":"ui_editor_properties_foliage"}
uniform float g_Direction; // {"material":"scrolldirection","label":"ui_editor_properties_direction","default":0,"range":[1.571,6.28],"direction":true,"group":"ui_editor_properties_foliage"}
uniform float g_CutOff; // {"material":"foliagecutoff","label":"ui_editor_properties_crunch","default":0.2,"range":[0.0, 0.39],"group":"ui_editor_properties_foliage"}
uniform float g_TreeHeight; // {"material":"foliageheight","label":"ui_editor_properties_tree_height","default":5,"range":[0.0, 100],"group":"ui_editor_properties_foliage"}
uniform float g_TreeRadius; // {"material":"foliageradius","label":"ui_editor_properties_tree_radius","default":0.5,"range":[0.0, 10],"group":"ui_editor_properties_foliage"}
uniform vec2 g_FoliageUVBounds; // {"material":"foliageuvbounds","label":"ui_editor_properties_leaves_uv_mapping","default":"0 1","nobindings":true,"conversion":"startdelta","group":"ui_editor_properties_foliage"}

void main() {
	vec3 localPos = a_Position;
	vec3 localNormal = a_Normal;

#if MORPHING
	ApplyMorphPositionNormal(CASTU(gl_VertexID), MAKE_SAMPLER2D_ARGUMENT(g_Texture5), g_Texture5Texel, g_MorphOffsets, g_MorphWeights, localPos, localNormal);
#endif

	vec4 worldPos;
	vec3 worldNormal;
#if SKINNING
	ApplySkinningPositionNormal(localPos, localNormal, a_BlendIndices, a_BlendWeights, worldPos, worldNormal);
#else
	ApplyPositionNormal(localPos, localNormal, worldPos, worldNormal);
#endif

	// <Foliage additions
#if LEAVESUVMODE
	vec2 leafUVs = a_TexCoord;
#else
	vec2 leafUVs = CAST2(1);
#endif

	worldPos.xyz += CalcFoliageAnimation(worldPos.xyz, localPos, leafUVs, g_Direction, g_Time,
		g_SpeedLeaves, g_SpeedBase, g_StrengthLeaves, g_StrengthBase,
		g_Phase, g_FoliageScale, g_CutOff, g_TreeHeight, g_TreeRadius, g_FoliageUVBounds);
	// Foliage additions>

	gl_Position = mul(worldPos, g_ViewProjectionMatrix);

	v_TexCoord.xy = a_TexCoord;
	v_ViewDir.xyz = g_EyePosition - worldPos.xyz;
	v_ViewDir.w = worldPos.y;

#if LIGHTING || REFLECTION
	v_WorldPos = worldPos.xyz;
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
#else
	v_WorldNormal = worldNormal;
#endif
#endif

#if REFLECTION
	ClipSpaceToScreenSpace(gl_Position, v_ScreenPos);
#endif

	v_LightAmbientColor = ApplyAmbientLighting(worldNormal);

#if FOLIAGEDEBUG
	float heightBlend = smoothstep(0.0, g_TreeHeight, localPos.y);
	
	float leafDistance = dot(localPos.xz, localPos.xz);
	vec2 blendParamsA = vec2(g_TreeRadius * g_TreeRadius, g_TreeRadius);
	vec2 blendParamsB = vec2(g_TreeRadius, g_TreeRadius * g_TreeRadius);
	vec2 blendParams = mix(blendParamsA, blendParamsB, step(1.0, g_TreeRadius));
	float radiusBlend = smoothstep(blendParams.x, blendParams.y, leafDistance);
#endif
#if FOLIAGEDEBUG == 1
	v_LightAmbientColor.rgb = vec3(radiusBlend, heightBlend, 0);
#elif FOLIAGEDEBUG == 2
	v_LightAmbientColor.rgb = vec3(0,heightBlend,0);
#elif FOLIAGEDEBUG == 3
	v_LightAmbientColor.rgb = vec3(radiusBlend, 0, 0);
#elif FOLIAGEDEBUG == 4
	float uvWeight = CalcLeavesUVWeight(leafUVs, g_FoliageUVBounds);
	v_LightAmbientColor.rgb = CAST3(uvWeight);
#elif FOLIAGEDEBUG == 5
	float colY = step(0.0, sin(worldPos.y * g_FoliageScale * 6.666));
	v_LightAmbientColor.rgb = CAST3(colY);
#endif
}
