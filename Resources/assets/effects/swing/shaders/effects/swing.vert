
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;

#if MASK == 1
varying vec2 v_TexCoordMask;
#endif

uniform float g_Time;

uniform float g_Amount; // {"material":"amount","label":"ui_editor_properties_amount","default":0.2,"range":[0,1]}
uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":2.0,"range":[-5,5]}
uniform float g_Phase; // {"material":"phase","label":"ui_editor_properties_time_offset","default":0.0,"range":[0,1]}

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);

	v_TexCoord.xy = a_TexCoord.xy;
	v_TexCoord.z = g_Texture0Resolution.x / g_Texture0Resolution.y;

	v_TexCoord.w = sin(g_Time * g_Speed + g_Phase * 6.28318530718) * g_Amount;

#if MASK == 1
	v_TexCoordMask = vec2(a_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						a_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
#endif
}
