
varying vec2 v_TexCoord;

uniform sampler2D g_Texture0;
uniform vec4 g_RenderVar0;

#if BICUBIC
vec4 cubic(float v)
{
	vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
	vec4 s = n * n * n;
	float x = s.x;
	float y = s.y - 4.0 * s.x;
	float z = s.z - 4.0 * s.y + 6.0 * s.x;
	float w = 6.0 - x - y - z;
	return vec4(x, y, z, w) * (1.0/6.0);
}

vec4 textureBicubic(vec2 texCoords)
{
	float sc = 0.5;
	vec2 texSize = sc / g_RenderVar0.xy;
	vec2 invTexSize = g_RenderVar0.xy / sc;

	texCoords = texCoords * texSize - 0.5;

	vec2 fxy = frac(texCoords);
	texCoords -= fxy;

	vec4 xcubic = cubic(fxy.x);
	vec4 ycubic = cubic(fxy.y);

	vec4 c = texCoords.xxyy + vec2 (-0.5, +1.5).xyxy;

	vec4 s = vec4(xcubic.xz + xcubic.yw, ycubic.xz + ycubic.yw);
	vec4 offset = c + vec4 (xcubic.yw, ycubic.yw) / s;

	offset *= invTexSize.xxyy;

	vec4 sample0 = texSample2D(g_Texture0, offset.xz);
	vec4 sample1 = texSample2D(g_Texture0, offset.yz);
	vec4 sample2 = texSample2D(g_Texture0, offset.xw);
	vec4 sample3 = texSample2D(g_Texture0, offset.yw);

	float sx = s.x / (s.x + s.y);
	float sy = s.z / (s.z + s.w);

	return mix(
		mix(sample3, sample2, sx), mix(sample1, sample0, sx)
	, sy);
}
#endif

#if BLOOM
uniform float g_BloomStrength; // {"material":"bloomstrength","default":2}
uniform vec4 g_BloomBlendParams; // {"material":"blend","default":"1 1 0 1"}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}
#endif

#if UPSAMPLE
uniform float g_BloomScatter; // {"material":"scatter","default":1}
#endif

void main() {
#if BICUBIC
	vec3 albedo = textureBicubic(v_TexCoord + g_RenderVar0.xy).rgb +
					textureBicubic(v_TexCoord + g_RenderVar0.zy).rgb +
					textureBicubic(v_TexCoord + g_RenderVar0.xw).rgb +
					textureBicubic(v_TexCoord + g_RenderVar0.zw).rgb;
#else
	vec3 albedo = texSample2D(g_Texture0, v_TexCoord + g_RenderVar0.xy).rgb +
					texSample2D(g_Texture0, v_TexCoord + g_RenderVar0.zy).rgb +
					texSample2D(g_Texture0, v_TexCoord + g_RenderVar0.xw).rgb +
					texSample2D(g_Texture0, v_TexCoord + g_RenderVar0.zw).rgb;
#endif

#if UPSAMPLE
	albedo *= 0.25 * g_BloomScatter;
#else
	albedo *= 0.25;
#endif

#if BLOOM
	albedo = max(CAST3(0), albedo);
	float brightness = max(albedo.r, max(albedo.g, albedo.b));
	float soft = brightness - g_BloomBlendParams.y;
	soft = clamp(soft, 0, g_BloomBlendParams.z);
	soft = soft * soft * g_BloomBlendParams.w;
	float contribution = max(soft, brightness - g_BloomBlendParams.x);
	contribution /= max(brightness, 0.00001);
	albedo *= contribution * g_BloomStrength * g_BloomTint;
#endif

	gl_FragColor = vec4(albedo, 1.0);
}
