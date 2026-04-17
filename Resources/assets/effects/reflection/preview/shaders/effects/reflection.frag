
varying vec4 v_TexCoord;
varying vec2 v_ReflectedCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/black"}

uniform float g_Additive; // {"material":"Additive","default":1,"range":[0,1]}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 reflected = texSample2D(g_Texture0, v_ReflectedCoord);
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	
	gl_FragColor = mix(mix(albedo, reflected, mask), albedo + reflected * mask, g_Additive);
}
