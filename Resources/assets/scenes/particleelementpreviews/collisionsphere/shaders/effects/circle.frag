
uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}

varying vec2 v_TexCoord;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	albedo.a = smoothstep(0.5, 0.49, length(v_TexCoord - vec2(0.5, 0.5)));
	gl_FragColor = albedo;
}
