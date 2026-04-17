uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

// The coordinates of the current pixel within the space spanning (0, 0) to (new x, new y).
varying vec2 v_PixelCoord;
// x and y are the width and height of a 'new' pixel in 0 to 1 coordinate space. z and w are the same for an old pixel
varying vec4 v_PixelSize;

uniform float u_ResolutionScale;  // {"material":"resolution_scale","label":"Resolution Scale","default":0.125,"range":[0.01, 1.0]}
uniform vec2 u_NewResolution;  // {"material":"new_resolution","label":"New Resolution","default":"960 540"}

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);

#if MULTIPLY
	v_PixelCoord = a_TexCoord * g_Texture0Resolution.xy * u_ResolutionScale;
	v_PixelSize.xy = 1.0 / (g_Texture0Resolution.xy * u_ResolutionScale);
#else
	v_PixelCoord = a_TexCoord * u_NewResolution;
	v_PixelSize.xy = 1.0 / (u_NewResolution);
#endif
	v_PixelSize.zw = 1.0 / g_Texture0Resolution.xy;
}
