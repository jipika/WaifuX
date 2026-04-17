
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture1Resolution;

uniform vec2 g_Scale; // {"material":"scale","label":"ui_editor_properties_ripple_scale","linked":true,"default":"1 1","range":[0,10]}
uniform float g_Strength; // {"material":"ripplestrength","label":"ui_editor_properties_strength","default":0.1,"range":[-1,1]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec3 v_RefractTexCoord;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord;
	v_RefractTexCoord.xy = a_TexCoord * g_Scale;
	v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
	v_RefractTexCoord.z = sign(g_Strength) * g_Strength * g_Strength;
}
