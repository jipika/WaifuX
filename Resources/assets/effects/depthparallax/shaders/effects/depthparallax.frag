
// [COMBO] {"material":"ui_editor_properties_quality","combo":"QUALITY","type":"options","default":1,"options":{"ui_editor_properties_basic":0,"ui_editor_properties_occlusion_performance":1,"ui_editor_properties_occlusion_quality":2}}

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_depth_map","mode":"depth","format":"r8","default":"util/black","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_depth","default":"1 1","linked":true,"range":[0.01, 2.0]}
uniform float g_Sensitivity; // {"material":"sens","label":"ui_editor_properties_perspective","default":1,"range":[-5.0, 5.0]}
uniform float g_Center; // {"material":"center","label":"ui_editor_properties_center","default":0.3,"range":[0.0, 1.0]}

//uniform mat4 g_EffectModelViewProjectionMatrixInverse;
//uniform mat4 g_EffectTextureProjectionMatrixInverse;
//uniform mat4 g_EffectTextureProjectionMatrix;

varying vec4 v_TexCoord;
varying vec2 v_ParallaxOffset;

#if MASK
varying vec2 v_TexCoordMask;
#endif

#if QUALITY != 0
vec2 ParallaxMapping(vec2 texCoords, vec2 viewDir)
{ 
#if QUALITY == 1
	float numLayers = 24;
#endif
#if QUALITY == 2
	float numLayers = 64;
#endif

	float layerDepth = 1.0 / numLayers;
	float currentLayerDepth = 1.0;
	vec2 P = viewDir.xy * g_Scale * 0.1;
	vec2 deltaTexCoords = P / numLayers;
	
	vec2  currentTexCoords     = texCoords;
	float currentDepthMapValue = texSample2D(g_Texture1, currentTexCoords).r;
	  
	for (float i=0.0; currentLayerDepth > currentDepthMapValue && i<numLayers; i++)
	{
		currentTexCoords -= deltaTexCoords;
		currentDepthMapValue = texSample2D(g_Texture1, currentTexCoords).r;
		currentLayerDepth -= layerDepth;
	}

	vec2 prevTexCoords = currentTexCoords + deltaTexCoords;

	float afterDepth  = currentDepthMapValue - currentLayerDepth;
	float beforeDepth = texSample2D(g_Texture1, prevTexCoords).r - currentLayerDepth - layerDepth;
	 
	float weight = afterDepth / (afterDepth - beforeDepth);
	vec2 finalTexCoords = prevTexCoords * weight + currentTexCoords * (1.0 - weight);

	return finalTexCoords;
}
#endif

void main() {
	float depth = texSample2D(g_Texture1, v_TexCoord.zw).r;
	float mask = 1.0;
	
#if MASK
	mask *= texSample2D(g_Texture2, v_TexCoordMask.xy).r;
#endif

#if QUALITY == 0
	vec2 pointer = vec2(v_TexCoord.z, 1.0 - v_TexCoord.w);
	pointer = (pointer - v_ParallaxOffset) * vec2(2.0, -2.0) * g_Scale * -0.04;
	vec2 offset = (depth * 2.0 - 1.0) * pointer * mask;
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy + offset);
#else
	float ctrlSign = step(0.0, g_Sensitivity);
	float negPerspective = -g_Sensitivity;
	float ctrlPerspOrtho = saturate(g_Sensitivity) + step(0.0001, negPerspective);

	vec2 prlx = mix(v_ParallaxOffset, CAST2(1.0) - v_ParallaxOffset, ctrlSign);

	vec2 coords = mix(v_TexCoord.xy, (v_TexCoord.xy - CAST2(0.5)) / (1.0 + g_Sensitivity * 0.2) + CAST2(0.5), ctrlSign);
	coords = coords - (prlx * 2 - 1) * g_Center * vec2(-0.05, 0.05) * g_Scale * mix(-1.0, negPerspective, ctrlPerspOrtho);

	vec2 pointer = vec2(1.0 - v_TexCoord.z, v_TexCoord.w);
	vec2 ctrlDir = (pointer - prlx);

	ctrlDir = mix(vec2(1.0 - prlx.x, prlx.y) - CAST2(0.5),
		ctrlDir * vec2(-negPerspective, negPerspective),
		ctrlPerspOrtho);
	
	vec2 fakeViewdir = ctrlDir;
	vec2 newCoords = ParallaxMapping(coords, fakeViewdir * mask);

	vec4 albedo = texSample2D(g_Texture0, newCoords);

	//albedo.rgb = vec3(v_ParallaxOffset, 0);
#endif
	
	gl_FragColor = albedo;
}
