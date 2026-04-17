
uniform sampler2D g_Texture0; // {"label":"ui_editor_properties_albedo","nonremovable":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_mask","nonremovable":true}

uniform vec4 g_RenderVar0;

varying vec2 v_TexCoord;

#if MORPHING || SKINNING_ALPHA
varying float v_VertexAlpha;
#endif

void main() {
	float albedoAlpha = texSample2D(g_Texture0, v_TexCoord.xy).a;
	float mask = texSample2D(g_Texture1, v_TexCoord.xy).r;

	// Reduce alpha for overlapping parts that are not masked
	vec4 color = vec4(mask, 0.0, 0.0, mix(pow(albedoAlpha, 4), albedoAlpha, mask));

	// Used for more expensive real clipping mask rendering
	//color.r = step(0.001, color.r);

	// Needed for cheap composition method
#if ALPHATOCOVERAGE
	//color.r += 0.02;
	color.a = saturate(color.a + 0.05);
#else
	//color.r = pow(color.r + 0.00000001, mix(0.5, 1.5, g_RenderVar0.x));
#endif

#if MORPHING || SKINNING_ALPHA
	color.a *= v_VertexAlpha;
#endif

	// Needed for color max blending
	color.r *= color.a;
	
	color.r = mix(color.r, 1.0 - color.r, g_RenderVar0.x);
	
	gl_FragColor = color;

#if ALPHATOCOVERAGE
	gl_FragColor.a = (gl_FragColor.a - 0.5) / max(fwidth(gl_FragColor.a), 0.0001) + 0.5;
#if GLSL
	if (gl_FragColor.a < 0.5) discard;
#endif
#endif
}
