
varying vec4 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}
uniform sampler2D g_Texture1; // {"material":"Flow map","mode":"flowmask","default":"util/noflow"}
uniform sampler2D g_Texture2; // {"material":"Flow Phase","mode":"opacitymask","default":"util/white"}
uniform float g_Time;

uniform float g_Speed; // {"material":"Speed","default":1,"range":[0.01, 10]}
uniform float g_Amp; // {"material":"Strength","default":0.2,"range":[0.01, 1]}
uniform float g_Power; // {"material":"Power","default":1,"range":[0.01, 2]}

void main() {

	float flowPhase = texSample2D(g_Texture2, v_TexCoord.zw).r * 6.28;
	vec2 flowColors = texSample2D(g_Texture1, v_TexCoord.zw).rg;
	vec2 flowMask = (flowColors.rg - vec2(0.498, 0.498)) * 2.0;
	
	float offset = sin(g_Speed * g_Time + flowPhase);
	offset = pow(abs(offset), g_Power) * sign(offset);
	
	vec2 texCoord = v_TexCoord.xy + flowMask * offset * g_Amp * g_Amp;
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
