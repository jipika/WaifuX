
varying vec2 v_TexCoord;
varying vec3 v_ScreenCoord;

uniform sampler2D g_Texture0; // {"hidden":true}

void main() {
	// Bypass v_ScreenCoord MVP path to avoid potential UV distortion on macOS.
	// v_TexCoord is already [0,1] for full-screen passthrough.
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
	
#if CLEARALPHA == 1
	gl_FragColor.a = 0;
#endif
}
