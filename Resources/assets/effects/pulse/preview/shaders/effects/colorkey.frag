
// [COMBO] {"material":"Invert","combo":"INVERT","type":"options","default":0}

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_KeyAlpha; // {"material":"Write alpha","default":0,"range":[0,1]}
uniform float g_KeyFuzz; // {"material":"Fuzziness","default":0,"range":[0,1]}
uniform float g_KeyTolerance; // {"material":"Tolerance","default":0.1,"range":[0,1]}
uniform vec3 g_KeyColor; // {"material":"Color", "type": "color", "default":"1 1 1"}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	
	float delta = length(g_KeyColor - albedo.rgb); // [0, SQRT_3]
	float blend = smoothstep(0.001, 0.002 + g_KeyFuzz, delta - g_KeyTolerance);
	
#if INVERT == 1
	blend = 1.0 - blend;
#endif
	
	albedo.a *= mix(g_KeyAlpha, 1.0, blend);
	
	gl_FragColor = albedo;
}
