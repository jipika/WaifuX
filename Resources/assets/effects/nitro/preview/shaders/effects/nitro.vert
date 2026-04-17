
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

#if MASK == 1
uniform vec4 g_Texture2Resolution;
#endif

uniform float g_Time;
uniform vec4 g_NitroSpeeds; // {"material":"ui_editor_properties_speed","default":"-0.1 0.7 0.1 0"}
uniform vec2 g_NitroScales; // {"material":"ui_editor_properties_scale","default":"1 2"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec4 v_TexCoordNitro;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	v_TexCoordNitro.xy = (a_TexCoord + g_Time * g_NitroSpeeds.xy) * g_NitroScales.x;
	v_TexCoordNitro.zw = (a_TexCoord + g_Time * g_NitroSpeeds.zw) * g_NitroScales.y;
	
	v_TexCoordNitro.xz *= aspect;
	
	v_TexCoordNitro.zw = vec2(-v_TexCoordNitro.w, v_TexCoordNitro.z);
	
#if MASK == 1
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
