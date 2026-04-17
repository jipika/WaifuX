
uniform mat4 g_ModelViewProjectionMatrix;
uniform float g_Time;

uniform float g_ScrollX; // {"material":"speedx","label":"ui_editor_properties_speed_x","default":0.2,"range":[-2,2]}
uniform float g_ScrollY; // {"material":"speedy","label":"ui_editor_properties_speed_y","default":0.2,"range":[-2,2]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoord;
varying vec2 v_Scroll;

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord = a_TexCoord;
	
	vec2 scroll = vec2(g_ScrollX, g_ScrollY);
	scroll = sign(scroll) * pow(vec2(g_ScrollX, g_ScrollY), CAST2(2.0));
	v_Scroll = scroll * g_Time;
}
