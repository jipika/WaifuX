
struct PS_OUTPUT
{
	float4 gl_FragColor : SV_TARGET;
};

struct VS_OUTPUT
{
	float4 gl_Position : SV_POSITION;
};

PS_OUTPUT main(VS_OUTPUT IN)
{
	PS_OUTPUT OUT;
	OUT.gl_FragColor = float4(0.5, 0, 0, 1);
	return OUT;
}
