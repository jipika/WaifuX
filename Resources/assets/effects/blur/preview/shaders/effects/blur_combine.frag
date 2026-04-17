
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/white"}
uniform sampler2D g_Texture2; // {"material":"Prev","hidden":true}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 albedoOld = texSample2D(g_Texture2, v_TexCoord.xy);
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	albedo = mix(albedoOld, albedo, mask);
	gl_FragColor = albedo;
}
