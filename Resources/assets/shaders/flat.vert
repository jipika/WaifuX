
uniform mat4 g_ModelViewProjectionMatrix;

attribute vec3 a_Position;
attribute vec4 a_Color;

#ifdef VERTEXCOLOR
varying vec4 v_Color;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
#ifdef VERTEXCOLOR
	v_Color = a_Color.rgba;
#endif
}
