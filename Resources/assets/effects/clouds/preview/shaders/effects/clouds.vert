
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

#if MASK == 1
uniform vec4 g_Texture2Resolution;
#endif

uniform float g_Time;
uniform vec2 g_CloudSpeeds; // {"material":"ui_editor_properties_speed","default":"0.01 -0.02"}
uniform vec2 g_CloudScales; // {"material":"ui_editor_properties_scale","default":"1.3 0.5"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec4 v_TexCoordClouds;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord.xyxy;
	
	float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;
	v_TexCoordClouds.xy = (a_TexCoord + g_Time * g_CloudSpeeds.x) * g_CloudScales.x;
	v_TexCoordClouds.zw = (a_TexCoord + g_Time * g_CloudSpeeds.y) * g_CloudScales.y;
	
	v_TexCoordClouds.zw = vec2(-v_TexCoordClouds.w, v_TexCoordClouds.z);
	
#if MASK == 1
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif
}
