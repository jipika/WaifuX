
uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_noise","default":"util/perlin_256"}

uniform float g_Time;

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.0, 2]}
uniform float g_Density; // {"material":"density","label":"ui_editor_properties_density","default":0.5,"range":[0.01, 1]}

varying vec4 v_TexCoord;
varying vec2 v_NoiseCoord;

void main() {
	vec4 albedo = CAST4(1);

	vec3 effectAlbedo = albedo.rgb;
	float density = g_Density * g_Density;
	float time = g_Time * g_Speed * density;

	vec2 noiseCoord = v_NoiseCoord;
	vec4 noise0 = texSample2D(g_Texture1, noiseCoord);
	noise0.r = noise0.r * (1.0 - noise0.g);
	float timer0 = frac(noise0.r * 100 + time);

	float glitterDensity = density * 0.5;
	float glitter0 = smoothstep(0.5 - glitterDensity, 0.5, timer0) * smoothstep(0.5 + glitterDensity, 0.5, timer0);

	glitter0 = smoothstep(0.5, 1.0, glitter0);
	glitter0 *= glitter0;
	effectAlbedo = CAST3(glitter0);

	albedo.rgb = effectAlbedo;

	gl_FragColor = albedo;
}
