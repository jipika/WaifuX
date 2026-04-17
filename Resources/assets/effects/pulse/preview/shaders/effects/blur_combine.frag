
varying vec4 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/white"}
uniform sampler2D g_Texture2; // {"material":"Prev","hidden":true}

#ifdef HLSL_SM30
uniform vec4 g_Texture0Resolution;
#endif

void main() {

	vec2 blurredCoords = v_TexCoord.xy;
	
#ifdef HLSL_SM30
	blurredCoords += 0.75 / g_Texture0Resolution.zw;
#endif

	vec4 blurred = texSample2D(g_Texture0, blurredCoords);
	vec4 albedoOld = texSample2D(g_Texture2, v_TexCoord.xy);
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	
	blurred = mix(albedoOld, blurred, mask);
	
	gl_FragColor = blurred;
}
