
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;
uniform vec2 g_HDRParams;

vec3 _srgb(vec3 v)
{
	return max(1.055 * pow(v, 0.416666667) - 0.055, 0.0);
}

void main() {
	vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
	albedo.rgb = _srgb(albedo.rgb / g_HDRParams.x);
	gl_FragColor = albedo;
}
