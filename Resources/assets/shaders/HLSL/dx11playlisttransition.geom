struct GS_INPUT
{
	float4 a_Position : SV_POSITION;
	float2 a_TexCoord : TEXCOORD0;
};

struct GS_OUTPUT
{
	float4 v_Position : SV_POSITION;
	float2 v_TexCoord : TEXCOORD0;
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

float2 rotateFloat2(float2 v, float r)
{
	float2 cs = float2(cos(r), sin(r));
	return float2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
}

#if FADEEFFECT == 16
// Bricks
#define BRICKS_PER_SET 7
#define SET_COUNT 4
float2 uvsFromInitialPosition(float2 initialPosition)
{
	float2 uvs = initialPosition * 0.5 + float2(0.5, 0.5);
	uvs.y = 1.0 - uvs.y;
	return uvs;
}

void makeBrickGeom(float2 origin, float angle, float2 size, float2 uvOrigin, inout TriangleStream<GS_OUTPUT> OutputStream)
{
	float2 halfSize = size * 0.5;
	halfSize *= float2(g_AspectRatio, 1.0);
	float2 halfSizeAnimX = rotateFloat2(float2(halfSize.x, 0.0), angle);
	float2 halfSizeAnimY = rotateFloat2(float2(0.0, halfSize.y), angle);
	halfSizeAnimX /= float2(g_AspectRatio, 1.0);
	halfSizeAnimY /= float2(g_AspectRatio, 1.0);

	float2 anim00 = float2(origin.x, origin.y) - halfSizeAnimX - halfSizeAnimY;
	float2 anim01 = float2(origin.x, origin.y) - halfSizeAnimX + halfSizeAnimY;
	float2 anim10 = float2(origin.x, origin.y) + halfSizeAnimX - halfSizeAnimY;
	float2 anim11 = float2(origin.x, origin.y) + halfSizeAnimX + halfSizeAnimY;
	
	float2 halfSizeUVS = size * 0.5;
	float2 pos00 = float2(uvOrigin.x - halfSizeUVS.x, uvOrigin.y - halfSizeUVS.y);
	float2 pos01 = float2(uvOrigin.x - halfSizeUVS.x, uvOrigin.y + halfSizeUVS.y);
	float2 pos10 = float2(uvOrigin.x + halfSizeUVS.x, uvOrigin.y - halfSizeUVS.y);
	float2 pos11 = float2(uvOrigin.x + halfSizeUVS.x, uvOrigin.y + halfSizeUVS.y);

	GS_OUTPUT OUT;
	OUT.v_Position = float4(anim00, 0, 1);
	OUT.v_TexCoord = uvsFromInitialPosition(pos00);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(anim01, 0, 1);
	OUT.v_TexCoord = uvsFromInitialPosition(pos01);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(anim10, 0, 1);
	OUT.v_TexCoord = uvsFromInitialPosition(pos10);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(anim11, 0, 1);
	OUT.v_TexCoord = uvsFromInitialPosition(pos11);
	OutputStream.Append(OUT);
	
	OutputStream.RestartStrip();
}

void makeBrick(float2 origin, float2 size, inout TriangleStream<GS_OUTPUT> OutputStream)
{
	float animPosY = origin.y * 0.5 + 0.5;
	float animPosX = origin.x * 0.5 + 0.5;
	float fallDuration = 0.3;
	float fallOffset = smoothstep(0.0, fallDuration, g_Progress * (1.0 + fallDuration * 1.5) - animPosY - animPosX * 0.2);
	fallOffset = pow(fallOffset, 2.0);
	
	float2 animOrigin = origin;
	animOrigin.y -= fallOffset * (animPosY + 0.2) * 2.6;
	animOrigin.x += fallOffset * origin.x * 0.333;
	
	float angle = fallOffset * 3.0 * -origin.x;

	makeBrickGeom(animOrigin, angle, size, origin, OutputStream);
}

[maxvertexcount(4 * BRICKS_PER_SET * SET_COUNT)]
void main(point GS_INPUT IN[1], inout TriangleStream<GS_OUTPUT> OutputStream)
{
	float setHeight = 2.0 / (SET_COUNT);
	float brickHeight = setHeight * 0.5;
	float brickWidth = 2.0 * 0.333334;
	float brickWidthHalf = brickWidth * 0.5;
	float brickHeightHalf = brickHeight * 0.5;

	float2 pos = float2(-1.0, -1.0);
	for (int set = 0; set < SET_COUNT; ++set)
	{
		// First row
		pos.x = -1.0;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.x += brickWidth;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.x += brickWidth;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);
		
		// Second row
		pos.x = -1.0 - brickWidthHalf;
		pos.y += brickHeight;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.x += brickWidth;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.x += brickWidth;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.x += brickWidth;
		makeBrick(pos + float2(brickWidthHalf, brickHeightHalf), float2(brickWidth, brickHeight), OutputStream);

		pos.y += brickHeight;
	}
}
#else
[maxvertexcount(4)]
void main(point GS_INPUT IN[1], inout TriangleStream<GS_OUTPUT> OutputStream)
{
	GS_OUTPUT OUT;
	OUT.v_Position = float4(-1, -1, 0, 1);
	OUT.v_TexCoord = float2(0, 1);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(-1, 1, 0, 1);
	OUT.v_TexCoord = float2(0, 0);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(1, -1, 0, 1);
	OUT.v_TexCoord = float2(1, 1);
	OutputStream.Append(OUT);

	OUT.v_Position = float4(1, 1, 0, 1);
	OUT.v_TexCoord = float2(1, 0);
	OutputStream.Append(OUT);
}
#endif
