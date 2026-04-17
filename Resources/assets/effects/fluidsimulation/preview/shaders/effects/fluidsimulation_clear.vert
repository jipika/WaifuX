
uniform float g_Frametime;

uniform float u_Pressure; // {"material":"pressure","label":"ui_editor_properties_pressure","default":0.8,"range":[0.0, 1.0],"group":"ui_editor_properties_simulation"}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec3 v_TexCoord;

void main() {
	gl_Position = vec4(a_Position, 1.0);
	v_TexCoord.xy = a_TexCoord.xy;
	v_TexCoord.z = pow(u_Pressure, 60 * g_Frametime);
}
