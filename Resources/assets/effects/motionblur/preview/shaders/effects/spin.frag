
// [COMBO] {"material":"Repeat","combo":"CLAMP","type":"options","default":1}

varying vec4 v_TexCoord;
varying vec2 v_TexCoordMask;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

#if MASK == 1
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","combo":"MASK","default":"util/black"}
#endif

void main() {
	vec2 texCoord = v_TexCoord.xy;
#if CLAMP
	texCoord = frac(texCoord);
#endif
	gl_FragColor = texSample2D(g_Texture0, texCoord);
	
#if MASK == 1
	float mask = texSample2D(g_Texture1, v_TexCoordMask).r;
	gl_FragColor = mix(texSample2D(g_Texture0, v_TexCoord.zw), gl_FragColor, mask);
#endif
}
