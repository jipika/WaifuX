
// [COMBO] {"material":"ui_editor_properties_quality","combo":"SAMPLES","type":"options","default":1,"options":{"4":0,"8":1,"15":2,"30":3}}

varying vec4 v_TexCoord01;
varying vec4 v_TexCoord23;
varying vec4 v_TexCoord45;

uniform sampler2D g_Texture0; // {"hidden":true}

uniform float g_Length; // {"material":"raylength","label":"ui_editor_properties_ray_length","default":0.1,"range":[0.01, 1]}
uniform float g_Intensity; // {"material":"rayintensity","label":"ui_editor_properties_ray_intensity","default":1,"range":[0.01, 2.0]}
uniform vec3 g_ColorRays; // {"material":"color","label":"ui_editor_properties_color","default":"1 1 1","type":"color"}

vec4 GatherDirection(vec2 texCoords, vec2 direction)
{
	vec4 albedo = CAST4(0.0);
	
#if SAMPLES == 0
	const int sampleCount = 4;
#endif
#if SAMPLES == 1
	const int sampleCount = 8;
#endif
#if SAMPLES == 2
	const int sampleCount = 15;
#endif
#if SAMPLES == 3
	const int sampleCount = 30;
#endif
#if SAMPLES == 4
	const int sampleCount = 50;
#endif

	float dist = length(direction);
	direction /= dist;
	
	dist *= g_Length;
	texCoords += direction * dist;

	const float sampleDrop = sampleCount - 1;
	
	direction = direction * dist / sampleDrop;
	for (int i = 0; i < sampleCount; ++i)
	{
		vec4 sample = texSample2D(g_Texture0, texCoords);
		texCoords -= direction;
		albedo += sample * (i / sampleDrop);
	}
	
	return albedo;
}

void main() {

	vec2 texCoords = v_TexCoord01.xy;
	vec4 albedo = CAST4(0.0);

#if EDGES == 2
	albedo += GatherDirection(texCoords, v_TexCoord01.zw);
	albedo += GatherDirection(texCoords, -v_TexCoord01.zw);
#endif
#if EDGES == 3
	albedo += GatherDirection(texCoords, v_TexCoord01.zw);
	albedo += GatherDirection(texCoords, v_TexCoord23.xy);
	albedo += GatherDirection(texCoords, v_TexCoord23.zw);
#endif
#if EDGES == 4
	albedo += GatherDirection(texCoords, v_TexCoord01.zw);
	albedo += GatherDirection(texCoords, -v_TexCoord01.zw);
	albedo += GatherDirection(texCoords, v_TexCoord23.xy);
	albedo += GatherDirection(texCoords, -v_TexCoord23.xy);
#endif
#if EDGES == 5
	albedo += GatherDirection(texCoords, v_TexCoord01.zw);
	albedo += GatherDirection(texCoords, v_TexCoord23.xy);
	albedo += GatherDirection(texCoords, v_TexCoord23.zw);
	albedo += GatherDirection(texCoords, v_TexCoord45.xy);
	albedo += GatherDirection(texCoords, v_TexCoord45.zw);
#endif


#if SAMPLES == 0
	const float sampleIntensity = 0.1 * (30 / 4.0);
#endif
#if SAMPLES == 1
	const float sampleIntensity = 0.1 * (30 / 8.0);
#endif
#if SAMPLES == 2
	const float sampleIntensity = 0.1 * (30 / 15.0);
#endif
#if SAMPLES == 3
	const float sampleIntensity = 0.1;
#endif
#if SAMPLES == 4
	const float sampleIntensity = 0.1 * (30 / 50.0);
#endif

	albedo.rgb *= g_ColorRays;
	gl_FragColor = vec4(g_Intensity * sampleIntensity * albedo.rgb, saturate(g_Intensity * sampleIntensity * albedo.a));
}
