
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec3 g_Screen;

in vec4 gl_Position;
in vec4 v_Color;

out vec4 v_Color;
out vec4 gl_Position;

PS_INPUT CreateParticleVertex(vec2 sprite, in VS_OUTPUT IN, vec3 right, vec3 up)
{
	PS_INPUT v;

	v.gl_Position = mul(vec4(IN.gl_Position.xyz, 1.0), g_ModelViewProjectionMatrix);
	v.gl_Position.xyz /= v.gl_Position.w;
	v.gl_Position.w = 1;
	v.gl_Position.xyz += (sprite.x * right + sprite.y * up) * IN.gl_Position.w * 0.002;
	
	v.v_Color = IN.v_Color;
	
	return v;
}

[maxvertexcount(4)]
void main() {

	float resFactor = min(1.0, 1080.0 / g_Screen.y);
	vec3 up = vec3(0, resFactor, 0);
	vec3 right = vec3(resFactor / g_Screen.z, 0, 0);
		
	OUT.Append(CreateParticleVertex(vec2(-1, 1), IN[0], right, up));
	OUT.Append(CreateParticleVertex(vec2(-1, -1), IN[0], right, up));
	OUT.Append(CreateParticleVertex(vec2(1, 1), IN[0], right, up));
	OUT.Append(CreateParticleVertex(vec2(1, -1), IN[0], right, up));
}
