
varying vec2 v_TexCoord[4];

uniform sampler2D g_Texture0;

uniform float g_BloomStrength; // {"material":"bloomstrength","default":2,"range":[0,4]}
uniform float g_BloomThreshold; // {"material":"bloomthreshold","default":0.65,"range":[0,0.999]}
uniform vec3 g_BloomTint; // {"material":"bloomtint","default":"1 1 1"}

void main() {
	vec3 albedo = texSample2D(g_Texture0, v_TexCoord[0]).rgb +
					texSample2D(g_Texture0, v_TexCoord[1]).rgb +
					texSample2D(g_Texture0, v_TexCoord[2]).rgb +
					texSample2D(g_Texture0, v_TexCoord[3]).rgb;
	albedo *= 0.25;

	float scale = max(max(albedo.x, albedo.y), albedo.z);
	albedo *= saturate(scale - g_BloomThreshold);

	// http://stackoverflow.com/a/34183839
	float grayscale = dot(vec3(0.2989, 0.5870, 0.1140), albedo);
	float sat = 1.0;
	albedo = -grayscale * sat + albedo * (1.0 + sat);

	gl_FragColor = vec4(max(CAST3(0), albedo * g_BloomStrength * g_BloomTint), 1.0);
}
