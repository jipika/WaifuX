
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;
uniform float g_Time;

uniform float g_FlowSpeed; // {"material":"speed","label":"ui_editor_properties_speed","default":1,"range":[0.01, 2]}
uniform float g_PhaseFeather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.4,"range":[0.1, 0.5]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec4 v_Cycles;
varying vec2 v_Blend;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);

	vec4 cycles = vec4(frac(g_Time * g_FlowSpeed),
						frac(g_Time * g_FlowSpeed + 0.5),
						frac(0.25 + g_Time * g_FlowSpeed),
						frac(0.25 + g_Time * g_FlowSpeed + 0.5));

	float blend = 2 * abs(cycles.x - 0.5);
	float blend2 = 2 * abs(cycles.z - 0.5);

	vec2 smoothParams = vec2(0.5 - g_PhaseFeather, 0.5 + g_PhaseFeather);
	blend = smoothstep(smoothParams.x, smoothParams.y, blend);
	blend2 = smoothstep(smoothParams.x, smoothParams.y, blend2);

	v_Cycles = cycles - CAST4(0.5);
	v_Blend = vec2(blend, blend2);
}
