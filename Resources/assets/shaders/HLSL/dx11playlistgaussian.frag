struct PS_OUTPUT
{
	float4 gl_FragColor : SV_TARGET;
};

struct VS_OUTPUT
{
	float4 gl_Position : SV_POSITION;
	float2 v_TexCoord : TEXCOORD0;
};

Texture2D g_Texture0:register(t0);
SamplerState g_Texture0SamplerState:register(s0);

static float weight[3][3] = {{21.0 / 256.0, 31.0 / 256.0, 21.0 / 256.0},
	{31.0 / 256.0, 48.0 / 256.0, 31.0 / 256.0},
	{21.0 / 256.0, 31.0 / 256.0, 21.0 / 256.0}};

PS_OUTPUT main(VS_OUTPUT IN)
{
	float3 color = (float3)0.0;

	float w;
	float h;
	g_Texture0.GetDimensions(w, h);
	float2 uvd = 3.333 / float2(w, h);

	for (int x = 0; x < 3; ++x)
	{
		for (int y = 0; y < 3; ++y)
		{
			color += g_Texture0.SampleLevel(g_Texture0SamplerState, IN.v_TexCoord + float2(x - 1, y - 1) * uvd, 0.0).rgb * weight[x][y];
		}
	}

	PS_OUTPUT OUT;
	OUT.gl_FragColor.rgb = color;
	OUT.gl_FragColor.a = 1.0;
	return OUT;
}
