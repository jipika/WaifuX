struct VS_INPUT
{
	float3 a_Position : POSITION;
	float2 a_TexCoord : TEXCOORD0;
#if FADEEFFECT == 23
	float3 a_Center : TEXCOORD1;
	float3 a_Normal : NORMAL;
#endif
};

struct VS_OUTPUT
{
	float4 v_Position : SV_POSITION;
	float2 v_TexCoord : TEXCOORD0;
#if FADEEFFECT == 23
	float2 v_TexCoordBase : TEXCOORD1;
	float3 v_WorldPos : TEXCOORD2;
	float3 v_WorldNormal : TEXCOORD3;
#endif
};

cbuffer g_bufDynamic:register(b0)
{
	const float g_Progress;
	const float g_Hash;
	const float g_Hash2;
	const float g_Random;

	const float g_AspectRatio;
	const float g_Width;
	const float g_Height;

	const float4x4 g_ViewProjection;
	const float4x4 g_ViewProjectionInv;
}

float nrand(float2 uv)
{
	return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
}

float2 rotateFloat2(float2 v, float r)
{
	float2 cs = float2(cos(r), sin(r));
	return float2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
}

float4x4 rotation3d(float3 axis, float angle)
{
  axis = normalize(axis);
  float s = sin(angle);
  float c = cos(angle);
  float oc = 1.0 - c;

  return float4x4(
    oc * axis.x * axis.x + c,           oc * axis.x * axis.y - axis.z * s,  oc * axis.z * axis.x + axis.y * s,  0.0,
    oc * axis.x * axis.y + axis.z * s,  oc * axis.y * axis.y + c,           oc * axis.y * axis.z - axis.x * s,  0.0,
    oc * axis.z * axis.x - axis.y * s,  oc * axis.y * axis.z + axis.x * s,  oc * axis.z * axis.z + c,           0.0,
    0.0,                                0.0,                                0.0,                                1.0
  );
}

VS_OUTPUT main(VS_INPUT IN)
{
	VS_OUTPUT OUT;

	OUT.v_Position = float4(IN.a_Position, 1.0);
	OUT.v_TexCoord = IN.a_TexCoord;

#if FADEEFFECT == 23
// Glass shatter
	float3 axis = float3(nrand(IN.a_Center * 247.0), nrand(IN.a_Center * 115.0), nrand(IN.a_Center * 531.0));
	axis -= (float3)0.5;
	axis = normalize(axis);

	float centerDistance = saturate(length(IN.a_Center));
	float animProgress = centerDistance * 0.05;
	animProgress = pow(smoothstep(0.4, 0.8, g_Progress - animProgress), 0.5);
	
	float3 center = IN.a_Center;
	
	float3 position = IN.a_Position - center;

	// Move them out of the center
	center = center * (1.0 + saturate((g_Progress - 0.4) * (1.0 / 0.6)) * 4.0);
	
	// Move pieaces up and down linearly
	center.y += pow(saturate((g_Progress - 0.4) * 2.5), 0.5) * 2.0 + saturate((g_Progress - 0.4)) * -5.0;

	// Apply creak offset
	float creakTimer = smoothstep(0.0, 0.06, g_Progress) * 0.05 +
		smoothstep(0.1, 0.14, g_Progress) * 0.08 +
		smoothstep(0.3, 0.36, g_Progress) * 0.15;
	float creakAmt = max(abs(IN.a_TexCoord.x - 0.5), abs(IN.a_TexCoord.y - 0.5)) * 0.5;
	float creakSmooth = 0.1;
	creakAmt = smoothstep(creakAmt, creakAmt + creakSmooth, creakTimer);

	float creakRand = nrand(position.xy * 100);
	float2 creakOffset = float2(0.02 / g_AspectRatio, 0.02) * (0.5 + creakRand * 1.0);
	position.xy *= lerp(1.0, max(step(IN.a_Position.z, -0.0001), 1.0 - creakOffset), creakAmt);

	float4x4 anim = rotation3d(axis, animProgress * g_Progress * 10.0);
	float4x4 animLight = rotation3d(axis, animProgress * g_Progress * 10.0 + creakAmt * 0.25);
	position = mul(float4(position, 0.0), anim).xyz;

	position += center;

	float3 worldSpaceNormal = mul(float4(IN.a_Normal, 0.0), animLight).xyz;
	float4 screenSpaceNormal = mul(float4(worldSpaceNormal, 0.0), g_ViewProjection);

	screenSpaceNormal.xyz = normalize(screenSpaceNormal.xyz);

	OUT.v_TexCoordBase = OUT.v_TexCoord;
	OUT.v_TexCoord.x -= screenSpaceNormal.x * 0.1;
	OUT.v_TexCoord.y -= screenSpaceNormal.y * 0.1;

	OUT.v_TexCoordBase = lerp(OUT.v_TexCoord, OUT.v_TexCoordBase, 0.1);

	OUT.v_Position = mul(float4(position, 1.0), g_ViewProjection);
	OUT.v_WorldPos = position;
	OUT.v_WorldNormal = worldSpaceNormal;
#endif

	return OUT;
}