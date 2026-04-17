
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;

uniform vec2 g_TexelSize;

// Proper gamma conversion http://chilliant.blogspot.com/2012/08/srgb-approximations-for-hlsl.html
vec3 srgb(vec3 v)
{
	vec3 c = step(0.04045, v);
	return c * (pow((v + 0.055) / 1.055, 2.4)) + (1 - c) * (v / 12.92);
}

void main()
{
	vec3 albedo = texSample2D(g_Texture0, v_TexCoord).rgb;
	gl_FragColor = vec4(srgb(saturate(albedo)), 1.0);
}
