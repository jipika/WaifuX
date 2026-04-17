
// [COMBO] {"material":"Greyscale","combo":"GREYSCALE","type":"options","default":0}

varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/white"}
uniform sampler2D g_Texture2; // {"material":"Prev","hidden":true}

uniform float g_Amount; // {"material":"Strength","default":1.0,"range":[0.01, 5]}

void main() {
	vec4 blurred = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 albedo = texSample2D(g_Texture2, v_TexCoord.xy);
	
	vec3 delta = albedo.rgb - blurred.rgb;
#if GREYSCALE == 1
	delta = CAST3(dot(vec3(0.11, 0.59, 0.3), delta));
#endif
	vec3 enhanced = albedo.rgb + delta * g_Amount;
	
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	albedo.rgb = mix(albedo.rgb, enhanced.rgb, mask);
	
	gl_FragColor = albedo;
}
