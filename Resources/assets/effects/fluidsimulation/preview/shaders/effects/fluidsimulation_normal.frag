
uniform sampler2D g_Texture0; // {"hidden":true}
uniform vec4 g_Texture0Resolution;

uniform float u_Depth; // {"material":"depth","label":"ui_editor_properties_depth","default":0.5,"range":[0,1],"group":"ui_editor_properties_material"}

varying vec2 v_TexCoord;

void main() {
	vec2 fxCoords = v_TexCoord.xy;
	float refAlpha = texSample2D(g_Texture0, fxCoords).a;

	vec2 ist = CAST2(1.0) / g_Texture0Resolution.xy;

	float s10 = texSample2D(g_Texture0, fxCoords + vec2(ist.x, 0.0)).a;
	float s01 = texSample2D(g_Texture0, fxCoords + vec2(0.0, ist.y)).a;

	vec2 base = vec2(s10 - refAlpha, s01 - refAlpha) * CAST2(25.0 * u_Depth);
	//float bLen = length(base) + 0.0001;
	//base /= bLen;
	//bLen = saturate(bLen);
	//base *= bLen * refAlpha;
	base = clamp(base, CAST2(-1.0), CAST2(1.0)) * refAlpha;

	vec3 normal = vec3(base, 0.0);
	normal.x = -normal.x;
	normal.z = sqrt(saturate(1.0 - normal.x * normal.x - normal.y * normal.y));

	gl_FragColor = vec4(normal * CAST3(0.5) + CAST3(0.5), 1.0);
}
