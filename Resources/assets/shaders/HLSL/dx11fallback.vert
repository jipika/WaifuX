
struct VS_INPUT
{
	float3 a_Position : POSITION;
};

struct VS_OUTPUT
{
	float4 gl_Position : SV_POSITION;
};

cbuffer g_bufDynamic:register(b1)
{
	const float4x4 g_ModelViewProjectionMatrix;
}

VS_OUTPUT main(VS_INPUT IN)
{
	VS_OUTPUT OUT;

	OUT.gl_Position = mul(float4(IN.a_Position, 1.0), g_ModelViewProjectionMatrix);

	return OUT;
}
