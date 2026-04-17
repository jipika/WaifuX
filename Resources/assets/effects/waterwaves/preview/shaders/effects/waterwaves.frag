
varying vec4 v_TexCoord;
varying vec2 v_Direction;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Mask","mode":"opacitymask","default":"util/white"}
uniform float g_Time;

uniform float g_Speed; // {"material":"Speed","default":5,"range":[0.01,50]}
uniform float g_Scale; // {"material":"Scale","default":200,"range":[0.01,1000]}
uniform float g_Strength; // {"material":"Strength","default":0.1,"range":[0.01,1]}

void main() {
	float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
	vec2 texCoord = v_TexCoord.xy;
	
	float distance = g_Time * g_Speed + dot(texCoord, v_Direction) * g_Scale;
	vec2 offset = vec2(v_Direction.y, -v_Direction.x);
	texCoord += sin(distance) * offset * g_Strength * g_Strength * mask;
	
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
