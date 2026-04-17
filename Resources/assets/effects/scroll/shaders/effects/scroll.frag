
varying vec2 v_TexCoord;
varying vec2 v_Scroll;

uniform sampler2D g_Texture0; // {"hidden":true}

uniform vec2 g_Scale; // {"material":"repeat","label":"ui_editor_properties_repeat","default":"1 1","linked":true,"range":[0.01, 10.0]}

void main() {
	vec2 texCoord = frac((v_TexCoord + v_Scroll) * g_Scale);
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
