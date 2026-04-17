
uniform mat4 g_ModelViewProjectionMatrix;

uniform vec4 g_Texture1Resolution;
uniform vec2 g_ParallaxPosition;
uniform vec3 g_Screen;

uniform mat4 g_EffectTextureProjectionMatrix;
uniform mat4 g_EffectTextureProjectionMatrixInverse;

#if MASK
uniform vec4 g_Texture2Resolution;
#endif

attribute vec3 a_Position;
attribute vec2 a_TexCoord;

varying vec4 v_TexCoord;
varying vec2 v_ParallaxOffset;

#if MASK
varying vec2 v_TexCoordMask;
#endif

void main() {
	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
	v_TexCoord.xy = a_TexCoord.xy;
	
	v_TexCoord.zw = vec2(a_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
						a_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
	
#if MASK
	v_TexCoordMask.xy = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
						v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
#endif

	mat3 rot = CAST3X3(g_EffectTextureProjectionMatrixInverse);
	vec2 projectedDirX = mul(vec3(1.0, 0.0, 0.0), rot).xy;
	vec2 projectedDirY = mul(vec3(0.0, 1.0, 0.0), rot).xy;
	
	projectedDirX = normalize(projectedDirX);
	projectedDirY = normalize(projectedDirY);
	
	vec2 prlxInput = g_ParallaxPosition * 2 - 1;
	v_ParallaxOffset = projectedDirX * prlxInput.x + projectedDirY * prlxInput.y;
	v_ParallaxOffset = v_ParallaxOffset * 0.5 + 0.5;

	//v_ParallaxOffset = g_ParallaxPosition;
}
