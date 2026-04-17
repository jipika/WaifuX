
uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform float g_Speed; // {"material":"Speed","default":1,"range":[0.01, 10]}
uniform float g_Strength; // {"material":"Strength","default":100,"range":[0.01, 500]}
uniform float g_Phase; // {"material":"Phase","default":0,"range":[0, 6.28]}
uniform float g_Power; // {"material":"Power","default":1,"range":[0.01, 2]}
uniform vec2 g_DirectionWeights; // {"material":"Direction weights","default":"1 0.2"}
uniform vec4 g_CornerWeights; // {"material":"Corner weights","default":"1 1 0 0"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;

void main() {
	vec3 position = a_Position;
	
	vec4 sines = g_Phase + g_Speed * g_Time * vec4(1, -0.16161616, 0.0083333, -0.00019841);
	sines = sin(sines);
	vec4 csines = 0.4 + g_Phase + g_Speed * g_Time * vec4(-0.5, 0.041666666, -0.0013888889, 0.000024801587);
	csines = sin(csines);
	
	sines = pow(abs(sines), g_Power) * sign(sines);
	csines = pow(abs(csines), g_Power) * sign(csines);
	
	float weight = saturate(g_CornerWeights.x * (1.0 - a_TexCoord.x) * (1.0 - a_TexCoord.y) +
					g_CornerWeights.y * (a_TexCoord.x) * (1.0 - a_TexCoord.y) +
					g_CornerWeights.z * (a_TexCoord.x) * (a_TexCoord.y) +
					g_CornerWeights.w * (1.0 - a_TexCoord.x) * (a_TexCoord.y));
	
	position.x += dot(sines, CAST4(1.0)) * g_Strength * weight * g_DirectionWeights.x;
	position.y += dot(csines, CAST4(1.0)) * g_Strength * weight * g_DirectionWeights.y;
	
	
	gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord;
}
