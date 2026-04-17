
uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_scale","default":"1 1","linked":true,"range":[0.01, 10.0]}
uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.01, 2.0]}
uniform float g_Rough; // {"material":"rough","label":"ui_editor_properties_smoothness","default":0.2,"range":[0.01, 1.0]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.5,"range":[0.01, 2.0]}

#if MASK
uniform vec4 g_Texture1Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec4 v_TexCoordIris;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
#if MASK
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif

	float dt = floor(g_Time * g_Speed);
	float ft = frac(g_Time * g_Speed);
	vec2 da0 = sin(1.7 * dt) + sin(2.3 * dt + vec2(1.0, 2.0));
	vec2 da1 = sin(1.7 * (dt + 1.0)) + sin(2.3 * (dt + 1.0) + vec2(1.0, 2.0));
	vec2 da = mix(da0, da1, smoothstep(1.0 - g_Rough, 1.0, ft));

	da.x += sin(g_Time * g_Speed) * g_NoiseAmount;
	da.y += cos(g_Time * g_Speed) * g_NoiseAmount;
	
	da *= g_Scale * 0.001;
	v_TexCoordIris = v_TexCoord + da.xyxy;
}
