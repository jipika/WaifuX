
varying vec4 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Water normal"}
uniform sampler2D g_Texture2; // {"material":"Mask","mode":"opacitymask","default":"util/white"}

uniform float g_Strength; // {"material":"Ripple strength","default":0.1,"range":[0,1]}

varying vec4 v_TexCoordRipple;

void main() {
	vec2 texCoord = v_TexCoord.xy;
	
	float mask = texSample2D(g_Texture2, v_TexCoord.zw).r;
	
	vec3 n1 = texSample2D(g_Texture1, v_TexCoordRipple.xy).xyz * 2 - 1;
	vec3 n2 = texSample2D(g_Texture1, v_TexCoordRipple.zw).xyz * 2 - 1;
	vec3 normal = normalize(vec3(n1.xy + n2.xy, n1.z));
	
	
	texCoord.xy += normal.xy * g_Strength * g_Strength * mask;
	
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
