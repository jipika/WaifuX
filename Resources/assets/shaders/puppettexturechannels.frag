
uniform vec4 g_Color4;

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1; // {"combo":"DOUBLEBUFFERED","hidden":true}

varying vec3 v_TexCoordBlend;
varying vec2 v_TexCoordBase;

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoordBlend.xy);

#if DOUBLEBUFFERED
#ifdef HLSL
	clip(v_TexCoordBlend.z - 0.001);
#else
	if (v_TexCoordBlend.z <= 0.001)
	{
		discard;
	}
#endif
	vec4 base = texSample2D(g_Texture1, v_TexCoordBase.xy);
	base.rgb = mix(albedo.rgb, base.rgb, step(saturate(v_TexCoordBlend.z), base.a));

	albedo = mix(base, albedo, v_TexCoordBlend.z);
	albedo *= g_Color4;

	gl_FragColor = albedo;
#else
	albedo.a *= saturate(v_TexCoordBlend.z);
	albedo.rgb *= g_Color4 * max(1.0, v_TexCoordBlend.z);

	gl_FragColor = albedo;
#endif
}
