
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;

uniform float g_DetectionSize; // {"material":"Detection size","default":1,"range":[0,5]}

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec2 v_TexCoordKernel[9];

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	
	vec2 texelSize = vec2(1.0 / g_Texture0Resolution.z, 1.0 / g_Texture0Resolution.w) * g_DetectionSize;
	
	v_TexCoordKernel[0] = a_TexCoord - texelSize;
	v_TexCoordKernel[1] = a_TexCoord - vec2(0.0, texelSize.y);
	v_TexCoordKernel[2] = a_TexCoord + vec2(texelSize.x, -texelSize.y);
	v_TexCoordKernel[3] = a_TexCoord - vec2(texelSize.x, 0.0);
	v_TexCoordKernel[4] = a_TexCoord;
	v_TexCoordKernel[5] = a_TexCoord + vec2(texelSize.x, 0.0);
	v_TexCoordKernel[6] = a_TexCoord + vec2(-texelSize.x, texelSize.y);
	v_TexCoordKernel[7] = a_TexCoord + vec2(0.0, texelSize.y);
	v_TexCoordKernel[8] = a_TexCoord + texelSize;
}
