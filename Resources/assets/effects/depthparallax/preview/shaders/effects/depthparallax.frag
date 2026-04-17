
// [COMBO] {"material":"ui_editor_properties_quality","combo":"QUALITY","type":"options","default":1,"options":{"ui_editor_properties_basic":0,"ui_editor_properties_occlusion_performance":1,"ui_editor_properties_occlusion_quality":2}}

varying vec4 v_TexCoord;

#if MASK
varying vec2 v_TexCoordMask;
#endif

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_depth_map","mode":"depth","format":"r8","default":"util/black","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_depth","default":"0.5 0.5","linked":true,"range":[0.01, 1.0]}
uniform float g_Sensitivity; // {"material":"sens","label":"ui_editor_properties_perspective","default":2,"range":[0.01, 5.0]}
uniform float g_Center; // {"material":"center","label":"ui_editor_properties_center","default":0.2,"range":[0.0, 1.0]}

uniform vec2 g_ParallaxPosition;

#if QUALITY != 0
vec2 ParallaxMapping(vec2 texCoords, vec2 viewDir)
{ 
#if QUALITY == 1
	int numLayers = 24;
#endif
#if QUALITY == 2
	int numLayers = 64;
#endif

	float layerDepth = 1.0 / numLayers;
	float currentLayerDepth = 1.0;
	vec2 P = viewDir.xy * g_Scale * 0.1;
	vec2 deltaTexCoords = P / numLayers;
	
	vec2  currentTexCoords     = texCoords;
	float currentDepthMapValue = texSample2D(g_Texture1, currentTexCoords).r;
	  
	for (int i=0; currentLayerDepth > currentDepthMapValue && i<numLayers; i++)
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
	pointer = (pointer - g_ParallaxPosition) * vec2(2.0, -2.0) * g_Scale * -0.04;
	vec2 offset = (depth * 2.0 - 1.0) * pointer * mask;
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy + offset);
#else
	vec2 coords = v_TexCoord.xy - (g_ParallaxPosition * 2 - 1) * g_Center * vec2(-0.2, 0.2) * g_Scale;

	vec2 pointer = vec2(1.0 - v_TexCoord.z, v_TexCoord.w);
	
	vec2 fakeViewdir = (pointer - g_ParallaxPosition) * vec2(-g_Sensitivity, g_Sensitivity);
	vec2 newCoords = ParallaxMapping(coords, fakeViewdir * mask);
	//vec2 newCoords = parallax_uv(v_TexCoord.xy, vec3(fakeViewdir, 1));
	
	

	vec4 albedo = texSample2D(g_Texture0, newCoords);
#endif
	
	gl_FragColor = albedo;
	
	//gl_FragColor.rgb = vec3(pointer, 0);
}
