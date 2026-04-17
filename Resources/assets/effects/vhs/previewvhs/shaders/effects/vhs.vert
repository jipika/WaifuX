

uniform mat4 g_ModelViewProjectionMatrix;

uniform vec4 g_Texture0Resolution;

#if MASK == 1
uniform vec4 g_Texture2Resolution;
#endif

uniform float g_Time;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec4 v_TexCoordGlitch;
varying vec4 v_TexCoordNoise;
varying vec4 v_TexCoordVHSNoise;

uniform float g_NoiseScale; // {"material":"scale","label":"ui_editor_properties_scale","default":0.3,"range":[0.01, 1.0]}
uniform float g_Chromatic; // {"material":"chromatic","label":"ui_editor_properties_chromatic_aberration","default":0.1,"range":[0.0, 1.0]}
uniform float g_ArtifactsScale; // {"material":"artifacts","label":"ui_editor_properties_artifacts","default":1.5,"range":[0.0, 3.0]}
uniform float g_NoiseAlpha; // {"material":"strength","label":"ui_editor_properties_alpha","default":1.0,"range":[0.0, 2.0]}

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	
	float t = frac(g_Time);
	v_TexCoord = a_TexCoord.xyxy;
	v_TexCoordNoise.xy = (a_TexCoord.xy + t) * g_NoiseScale;
	v_TexCoordNoise.zw = (a_TexCoord.xy - t * 2.5) * g_NoiseScale * 0.52;
	v_TexCoordNoise *= vec4(aspect, 1.0, aspect, 1.0);
	
#if MASK == 1
	v_TexCoord.zw = vec2(a_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						a_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif

	v_TexCoordVHSNoise.xy = v_TexCoordNoise.xy * vec2(0.1, 10) * g_ArtifactsScale;
	v_TexCoordVHSNoise.zw = v_TexCoordNoise.zw * vec2(0.01, 2) * g_ArtifactsScale;
	
	
	v_TexCoordGlitch = v_TexCoord.xyxy;
	
	vec3 glitchOffset = g_Chromatic * smoothstep(0, 2, 1 + 0.5 * sin(g_Time * vec3(11, 7, 13) * 2)) * vec3(0.007, 0.008, 0.0075);
	v_TexCoordGlitch.y += 0.004 * g_Chromatic + glitchOffset.x;
	v_TexCoordGlitch.xz += glitchOffset.xy + vec2(0.005, -0.0005) * g_Chromatic;
	v_TexCoordGlitch.z -= glitchOffset.z + 0.006 * g_Chromatic;
	v_TexCoordGlitch.w -= 0.0045 * g_Chromatic;
	v_TexCoord.x += glitchOffset.z * min(1.0, g_NoiseAlpha);
	v_TexCoord.y -= glitchOffset.z * min(1.0, g_NoiseAlpha);
}
