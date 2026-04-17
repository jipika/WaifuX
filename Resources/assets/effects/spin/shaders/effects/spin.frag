
// [COMBO] {"material":"ui_editor_properties_repeat","combo":"REPEAT","type":"options","default":1}

varying vec4 v_TexCoord;
varying vec2 v_TexCoordMask;
varying vec2 v_TexCoordSoftMask;

uniform vec4 g_Texture0Resolution;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec2 g_SpinCenter; // {"material":"center","label":"ui_editor_properties_center","default":"0.5 0.5","position":true}
uniform float g_Size; // {"material":"size","label":"ui_editor_properties_size","default":0.1,"range":[0,1]}
uniform float g_Feather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.002,"range":[0,0.2]}

void main() {
	vec2 texCoord = v_TexCoord.xy;

#if REPEAT
	texCoord = frac(texCoord);
#endif
	gl_FragColor = texSample2D(g_Texture0, texCoord);
	
	vec2 maskDelta = v_TexCoordSoftMask.xy - g_SpinCenter;
	float mask = smoothstep(g_Size + g_Feather + 0.00001, g_Size - g_Feather, length(maskDelta));

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoordMask).r;
#endif

	gl_FragColor = mix(texSample2D(g_Texture0, v_TexCoord.zw), gl_FragColor, mask);
}
