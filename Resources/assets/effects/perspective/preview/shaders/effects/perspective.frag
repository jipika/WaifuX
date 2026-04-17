
// [COMBO] {"material":"Repeat","combo":"REPEAT","type":"options","default":1}

varying vec3 v_TexCoord;

uniform sampler2D g_Texture0; // {"material":"Framebuffer","hidden":true}

uniform float g_Top; // {"material":"Top","default":1,"range":[-1,2]}
uniform float g_Bottom; // {"material":"Bottom","default":1,"range":[-1,2]}
uniform float g_Left; // {"material":"Left","default":1,"range":[-1,2]}
uniform float g_Right; // {"material":"Right","default":1,"range":[-1,2]}


void main() {
	vec2 texCoord = v_TexCoord.xy / v_TexCoord.z;
	
#if MODE == 0
	texCoord -= CAST2(0.5);
	//texCoord.x += v_Perspective.x / v_TexCoord.x;
	
	//texCoord.x *= 1.0 + (1.0 - v_TexCoord.y) * g_Top * (1.0 / (1.0 - v_TexCoord.y)) +
	//				v_TexCoord.y * g_Bottom;
	//texCoord.y *= (1.0 - v_TexCoord.x) * g_Left +
	//				v_TexCoord.x * g_Right;
	texCoord += CAST2(0.5);
#endif



#if REPEAT
	texCoord = frac(texCoord);
#endif
	gl_FragColor = texSample2D(g_Texture0, texCoord);
	
	//gl_FragColor = vec4(v_TexCoord.xy, 0, 1);
}
