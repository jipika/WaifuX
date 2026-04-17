
attribute vec3 a_Position;
attribute vec2 a_TexCoord;

uniform vec2 g_TexelSize;

varying vec2 v_TexCoord[13];

void main() {
	gl_Position = vec4(a_Position, 1);
	
	float localTexel = g_TexelSize.x * 8.0;
	v_TexCoord[0] = vec2(a_TexCoord.x - localTexel * 6.0, a_TexCoord.y);
	v_TexCoord[1] = vec2(a_TexCoord.x - localTexel * 5.0, a_TexCoord.y);
	v_TexCoord[2] = vec2(a_TexCoord.x - localTexel * 4.0, a_TexCoord.y);
	v_TexCoord[3] = vec2(a_TexCoord.x - localTexel * 3.0, a_TexCoord.y);
	v_TexCoord[4] = vec2(a_TexCoord.x - localTexel * 2.0, a_TexCoord.y);
	v_TexCoord[5] = vec2(a_TexCoord.x - localTexel, a_TexCoord.y);
	v_TexCoord[6] = vec2(a_TexCoord.x, a_TexCoord.y);
	v_TexCoord[7] = vec2(a_TexCoord.x + localTexel, a_TexCoord.y);
	v_TexCoord[8] = vec2(a_TexCoord.x + localTexel * 2.0, a_TexCoord.y);
	v_TexCoord[9] = vec2(a_TexCoord.x + localTexel * 3.0, a_TexCoord.y);
	v_TexCoord[10] = vec2(a_TexCoord.x + localTexel * 4.0, a_TexCoord.y);
	v_TexCoord[11] = vec2(a_TexCoord.x + localTexel * 5.0, a_TexCoord.y);
	v_TexCoord[12] = vec2(a_TexCoord.x + localTexel * 6.0, a_TexCoord.y);
}
