struct VS_INPUT
{
	float3 a_Position : POSITION;
	float2 v_TexCoord : TEXCOORD0;
};

struct VS_OUTPUT
{
	float4 a_Position : SV_POSITION;
	float2 v_TexCoord : TEXCOORD0;
};

VS_OUTPUT main(VS_INPUT IN)
{
	VS_OUTPUT OUT;

	OUT.a_Position = float4(IN.a_Position, 1.0);
	OUT.v_TexCoord = IN.v_TexCoord;

	return OUT;
}