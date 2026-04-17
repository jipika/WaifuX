
uniform vec4 g_RenderVar0;

varying vec2 g_TexCoord;

void main() {
	float dist = length(g_TexCoord - CAST2(0.5)) / 0.5;
	
	//dist = smoothstep(1 - 0.4999 * g_RenderVar0.y, 0.4999 * g_RenderVar0.y, dist);
	float delta = (1 - 0.4999 * g_RenderVar0.y) - (0.4999 * g_RenderVar0.y);
	dist = (dist - 0.4999 * g_RenderVar0.y) / delta;
	dist = 1.0 - max(0, min(1, dist));
	
	dist = max(0, min(1, dist));
	gl_FragColor = vec4(vec3(1, 0, 0), dist * g_RenderVar0.x);
}
