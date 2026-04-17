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

struct PS_OUTPUT
{
	float4 p_FragColor : SV_TARGET;
};

Texture2D g_Texture0:register(t0);
Texture2D g_Texture0MipMapped:register(t0);
Texture2D g_Texture1Noise:register(t1);
Texture2D g_Texture2Clouds:register(t2);

SamplerState g_Texture0SamplerState:register(s0);
SamplerState g_Texture0SamplerStateWrap:register(s1);

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

float3 mod289(float3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 mod289(float2 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 permute(float3 x) {
	return mod289(((x*34.0)+10.0)*x);
}

float snoise(float2 v)
{
	const float4 C = float4(0.211324865405187,
		0.366025403784439,
		-0.577350269189626,
		0.024390243902439);
	float2 i  = floor(v + dot(v, C.yy) );
	float2 x0 = v -   i + dot(i, C.xx);

	float2 i1;
	i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
	float4 x12 = x0.xyxy + C.xxzz;
	x12.xy -= i1;

	i = mod289(i);
	float3 p = permute( permute( i.y + float3(0.0, i1.y, 1.0 ))
		+ i.x + float3(0.0, i1.x, 1.0 ));

	float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
	m = m*m ;
	m = m*m ;

	float3 x = 2.0 * frac(p * C.www) - 1.0;
	float3 h = abs(x) - 0.5;
	float3 ox = floor(x + 0.5);
	float3 a0 = x - ox;

	m *= 1.79284291400159 - 0.85373472095314 * ( a0*a0 + h*h );

	float3 g;
	g.x  = a0.x  * x0.x  + h.x  * x0.y;
	g.yz = a0.yz * x12.xz + h.yz * x12.yw;
	return 127.0 * dot(m, g);
}

float4 mod289(float4 x) {
  return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 permute(float4 x) {
     return mod289(((x*34.0)+10.0)*x);
}

float4 taylorInvSqrt(float4 r)
{
  return 1.79284291400159 - 0.85373472095314 * r;
}

float snoise(float3 v)
{
	const float2  C = float2(1.0/6.0, 1.0/3.0) ;
	const float4  D = float4(0.0, 0.5, 1.0, 2.0);

	float3 i  = floor(v + dot(v, C.yyy) );
	float3 x0 =   v - i + dot(i, C.xxx) ;

	float3 g = step(x0.yzx, x0.xyz);
	float3 l = 1.0 - g;
	float3 i1 = min( g.xyz, l.zxy );
	float3 i2 = max( g.xyz, l.zxy );
	float3 x1 = x0 - i1 + C.xxx;
	float3 x2 = x0 - i2 + C.yyy;
	float3 x3 = x0 - D.yyy;

	i = mod289(i);
	float4 p = permute(permute(permute(
		i.z + float4(0.0, i1.z, i2.z, 1.0 ))
		+ i.y + float4(0.0, i1.y, i2.y, 1.0 ))
		+ i.x + float4(0.0, i1.x, i2.x, 1.0 ));

	float n_ = 0.142857142857;
	float3  ns = n_ * D.wyz - D.xzx;

	float4 j = p - 49.0 * floor(p * ns.z * ns.z);

	float4 x_ = floor(j * ns.z);
	float4 y_ = floor(j - 7.0 * x_ );

	float4 x = x_ *ns.x + ns.yyyy;
	float4 y = y_ *ns.x + ns.yyyy;
	float4 h = 1.0 - abs(x) - abs(y);

	float4 b0 = float4( x.xy, y.xy );
	float4 b1 = float4( x.zw, y.zw );

	float4 s0 = floor(b0)*2.0 + 1.0;
	float4 s1 = floor(b1)*2.0 + 1.0;
	float4 sh = -step(h, (float4)0.0);

	float4 a0 = b0.xzyw + s0.xzyw*sh.xxyy ;
	float4 a1 = b1.xzyw + s1.xzyw*sh.zzww ;

	float3 p0 = float3(a0.xy,h.x);
	float3 p1 = float3(a0.zw,h.y);
	float3 p2 = float3(a1.xy,h.z);
	float3 p3 = float3(a1.zw,h.w);

	float4 norm = taylorInvSqrt(float4(dot(p0,p0), dot(p1,p1), dot(p2, p2), dot(p3,p3)));
	p0 *= norm.x;
	p1 *= norm.y;
	p2 *= norm.z;
	p3 *= norm.w;

	float4 m = max(0.5 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
	m = m * m;
	return 105.0 * dot( m*m, float4( dot(p0,x0), dot(p1,x1), 
		dot(p2,x2), dot(p3,x3)));
}

float fbm(in float2 st, const in int octaves)
{
	float value = 0.0;
	float amplitude = .5;
	float frequency = 0.;
	for (int i = 0; i < octaves; i++)
	{
		value += amplitude * snoise(st);
		st *= 2.;
		amplitude *= .5;
	}
	return value;
}

float nrand(float2 uv)
{
	return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
}

float nrandFloorAspect(float2 uv, float scale)
{
	float2 aspectScale = scale * float2(g_AspectRatio, 1.0);
	return nrand(floor(frac(uv + g_Hash) * aspectScale) / aspectScale);
}

float3 blur13(float2 u, float2 d)
{
	float2 o1 = (float2)(1.4091998770852122) * d;
	float2 o2 = (float2)(3.2979348079914822) * d;
	float2 o3 = (float2)(5.2062900776825969) * d;
	return g_Texture0.SampleLevel(g_Texture0SamplerState, u, 0.0).rgb * 0.1976406528809576
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u + o1, 0.0).rgb * 0.2959855056006557
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u - o1, 0.0).rgb * 0.2959855056006557
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u + o2, 0.0).rgb * 0.0935333619980593
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u - o2, 0.0).rgb * 0.0935333619980593
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u + o3, 0.0).rgb * 0.0116608059608062
	+ g_Texture0.SampleLevel(g_Texture0SamplerState, u - o3, 0.0).rgb * 0.0116608059608062;
}

float drawGradient(float2 uvs, float2 start, float2 end, inout float distFromRay)
{
	float2 dir = end - start;
	float2 delta = uvs - start;
	float len = length(dir);
	dir /= len;
	
	float distAlongRay = dot(dir, delta) / len;
	distFromRay = abs(dot(float2(dir.y, -dir.x), delta));
	return distAlongRay;
}

float4 PerformEffect(VS_OUTPUT IN, float2 texCoord, float progress)
{
	float4 color = float4(g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).rgb, 1.0);

#if FADEEFFECT == 0
// Fade
	color.a = 1.0 - progress;
	color.rgb *= color.a;
#elif FADEEFFECT == 1
// Mosaic
	float r = nrandFloorAspect(texCoord, 50.0);
	float smooth = 0.5;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	color.rgb *= color.a;
#elif FADEEFFECT == 2
// Diffuse
	float r = nrandFloorAspect(texCoord, 1000.0);
	float smooth = 0.5;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	color.rgb *= color.a;
#elif FADEEFFECT == 3
// Horizontal slide
	texCoord.x -= progress;
	color = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0);
	color.a = step(0.0, texCoord.x);
	color.rgb *= color.a;
#elif FADEEFFECT == 4
// Vertical slide
	texCoord.y -= progress;
	color = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0);
	color.a = step(0.0, texCoord.y);
	color.rgb *= color.a;
#elif FADEEFFECT == 5
// Horizontal fade
	float smooth = 0.5;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - texCoord.x));
	color.rgb *= color.a;
#elif FADEEFFECT == 6
// Vertical fade
	float smooth = 0.5;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - texCoord.y));
	color.rgb *= color.a;
#elif FADEEFFECT == 7
// Cloud blend
	float2 noiseUV = texCoord * float2(g_AspectRatio, 1.0);
	float r = fbm(noiseUV + g_Hash, 6);
	r = smoothstep(-0.5, 0.5, r);
	float smooth = 0.333;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	color.rgb *= color.a;
#elif FADEEFFECT == 8
// Burnt paper
	float2 noiseUV = texCoord * float2(g_AspectRatio, 1.0);
	float r = fbm(noiseUV + g_Hash, 6);
	r = smoothstep(-0.8, 1.0, r);
	float rNoise = snoise(noiseUV * 55.333 * (0.5 + g_Progress) + g_Hash + g_Progress * 50.0);
	rNoise = smoothstep(-1.5, 1.0, rNoise);

	float smooth = 0.00001;
	float smoothDistort = 0.666;
	float smoothDistortColor = 0.05;
	float smoothDistortBurn = 0.5;
	float smoothShadow = 0.1;
	float rp = smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	float rpOffset = smoothstep(0.0, smoothDistort * progress, progress * (1.0 + smoothDistort) - r);

	float2 offset = float2(ddx(r), ddy(r)) * pow(rpOffset, 2.0) * -30.0;
	color = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord + offset, 0.0);

	color.a = 1.0 - rp;
	float shadow = (1.0 - step(0.01, color.a)) * smoothstep(smoothShadow * 2, smoothShadow, progress * (1.0 + smoothShadow) - r);
	float colorOrangeAmt = smoothstep(0.0, smoothDistortColor * progress, progress * (1.0 + smoothDistortColor) - r) * step(shadow, 0.0);
	float darkenSrc = smoothstep(smoothDistortBurn * (progress * 0.5), smoothDistortBurn * (progress * 0.8), progress * (1.0 + smoothDistortBurn) - r);

	color.rgb = lerp(color.rgb, color.rgb * 0.1 * float3(0.4, 0.03, 0.01), darkenSrc);
	color.rgb = lerp(color.rgb, float3(1, 0.333, 0) * rNoise * 1.5, colorOrangeAmt);
	color.a *= pow(1.0 - smoothstep(0.9, 1.0, progress), 0.5);

	color.rgb = lerp(color.rgb, (float3)0.0, step(0.001, shadow));
	color.a = max(color.a, pow(shadow, 2.0) * 0.5);

	float smoothDistortGlow = 0.05;
	float glowAmt = smoothstep(0.0, smoothDistortGlow * progress, progress * (1.0 + smoothDistortGlow) - r) *
		smoothstep(smoothDistortGlow * progress, 0.0, progress * (1.0 - smoothDistortGlow) - r);
	glowAmt *= 1.0 - progress;

	glowAmt = max(0.0, glowAmt - colorOrangeAmt);
	glowAmt = pow(glowAmt, 2.0);
	color.a = max(glowAmt, color.a);
	color.rgb += 2.0 * glowAmt * float3(1, 0.333, 0);

	color.rgb *= color.a;
#elif FADEEFFECT == 9
// Circular blend
	float2 delta = texCoord - float2(0.5, 0.5);
	delta.x *= g_AspectRatio;
	float dist = length(delta);
	float smooth = 0.1;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - dist));
	color.rgb *= color.a;
#elif FADEEFFECT == 10
// Zipper
	float delta = texCoord.x - 0.5;
	float offset = step(delta, 0.0) * 2.0 - 1.0;
	float smoothY = 0.5;
	float smooth = 0.333;
	float side = step(0.5, texCoord.x);
	float progressZipper = max(0.0, progress * (1.0 + smoothY) - texCoord.y * smoothY);
	progressZipper = smoothstep(0.0, 1.0, pow(progressZipper, 2.0));

	float2 uvs = texCoord;
	uvs.x += offset * progressZipper * (0.5 + smooth);

	color = g_Texture0.SampleLevel(g_Texture0SamplerState, uvs, 0.0);
	color.a = lerp(step(uvs.x, 0.5), step(0.5, uvs.x), side);

	float shadow = 1.0 - lerp(smoothstep(0.5, 0.5 + smooth, uvs.x), smoothstep(0.5, 0.5 - smooth, uvs.x), side);
	color.rgb = lerp(color.rgb, (float3)0.0, step(shadow, 0.9999));
	color.a = max(color.a, shadow * 0.5);
	color.rgb *= color.a;
#elif FADEEFFECT == 11
// Door
	float delta = texCoord.x - 0.5;
	float offset = step(delta, 0.0) * 2.0 - 1.0;
	float smooth = 0.333;
	float side = step(0.5, texCoord.x);

	float2 uvs = texCoord;
	uvs.x += offset * progress * (0.5 + smooth);
	
	color = g_Texture0.SampleLevel(g_Texture0SamplerState, uvs, 0.0);
	color.a = lerp(step(uvs.x, 0.5), step(0.5, uvs.x), side);

	float shadow = 1.0 - lerp(smoothstep(0.5, 0.5 + smooth, uvs.x), smoothstep(0.5, 0.5 - smooth, uvs.x), side);
	color.rgb = lerp(color.rgb, (float3)0.0, step(shadow, 0.9999));
	color.a = max(color.a, shadow * 0.5);
	color.rgb *= color.a;
#elif FADEEFFECT == 12
// Lines
	float r = nrandFloorAspect(float2(0.0, texCoord.y), 100.0);
	float smooth = 0.2;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	color.rgb *= color.a;
#elif FADEEFFECT == 13
// Zoom
	float2 deltaC = texCoord - float2(0.5, 0.5);
	deltaC.x *= g_AspectRatio;
	float dist = length(deltaC);
	float smooth = 1.0;
	float distortUVAmt = smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - dist));

	float2 delta = texCoord - float2(0.5, 0.5);
	delta.x *= g_AspectRatio;
	texCoord -= (float2)0.5;
	//texCoord *= 1.0 - distortUVAmt;
	texCoord *= 1.0 - progress * 0.5 * distortUVAmt * 2.0;
	texCoord += (float2)0.5;
	color.rgb = (blur13(texCoord, progress * 50.0 * delta / g_Height) + blur13(texCoord, progress * 33.0 * delta / g_Height)) * 0.5;
	color.a = 1.0 - progress;
	color.rgb *= color.a;
#elif FADEEFFECT == 14
// Drip vertical
	float r = smoothstep(-0.5, 0.5, fbm(float2(texCoord.x * 10.0 + g_Hash, 0.0), 2));
	float2 uvs = texCoord;
	
	float smooth = 0.2;
	uvs.y -= max(0.0, progress * (1.0 + smooth) - r * smooth);
	uvs.y -= texCoord.y * progress;
	color = g_Texture0.SampleLevel(g_Texture0SamplerState, uvs, 0.0);
	//float r = nrandFloorAspect(float2(0.0, texCoord.y), 100.0);
	color.a = step(0.0, uvs.y); // - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - r));
	
	float shadow = smoothstep(-0.1333, 0.0, uvs.y);
	color.rgb = lerp(color.rgb, (float)0.0, step(uvs.y, 0.0));
	color.a = max(color.a, shadow * (1.0 - progress));
	color.rgb *= color.a;
#elif FADEEFFECT == 15
// Pixelate
	float2 scale = floor((10.0 + g_Height * (1.0 - pow(abs(progress), 0.1))) * float2(g_AspectRatio, 1.0));
	color.a = 1.0 - smoothstep(0.7, 1.0, progress);
	texCoord -= (float2)0.5;
	texCoord *= scale;
	texCoord = floor(texCoord);
	texCoord /= scale;
	texCoord += (float2)0.5;
	color.rgb = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).rgb;
	color.rgb *= color.a;
#elif FADEEFFECT == 16
// Bricks
	color.a = 1.0;
#elif FADEEFFECT == 17
// Paint
	float2 noiseUV = texCoord * float2(g_AspectRatio, 1.0);
	float h = (g_Hash - 0.5) * 0.1;

	float rayDist0;
	float grad0 = drawGradient(texCoord, float2(-1, -0.2 + h), float2(1, 0.15 + h), rayDist0);
	grad0 *= step(rayDist0, 0.4);

	float rayDist1;
	float grad1 = drawGradient(texCoord, float2(1.5, 0.1 + h), float2(0, 0.53 + h), rayDist1);
	grad1 *= step(rayDist1, 0.4);

	float rayDist2;
	float grad2 = drawGradient(texCoord, float2(-0.5, 0.6 + h), float2(1.2, 0.8 + h), rayDist2);
	grad2 *= step(rayDist2, 0.4);

	grad0 = saturate(grad0);
	grad1 = saturate(grad1);
	grad2 = saturate(grad2);

	float v0 = grad0 * 0.25;
	v0 = step(0.001, v0);
	float v1 = grad1 * 0.25;
	v1 = step(0.001, v1);
	float v2 = grad2 * 0.25;
	v2 = step(0.001, v2);
	
	float l0 = grad0 * 0.25;
	float l1 = (0.333 + grad1 * 0.25);
	float l2 = (0.666 + grad2 * 0.333);

	float r = fbm(noiseUV * 10.0 + g_Hash, 8);
	r = smoothstep(-1.0, 1.0, r);
	float rs = fbm(noiseUV * 10.0 + g_Hash, 3);
	rs = smoothstep(-1.0, 1.0, rs);
	progress += r * 0.02;
	
	float mask0 = step(rayDist0, 0.4 - r * 0.1);
	float mask1 = step(rayDist1, 0.4 - r * 0.1);
	float mask2 = step(rayDist2, 0.4 - r * 0.1);
	
	float shadowMask0 = max(0.0, smoothstep(0.03, 0.0, max(0.0, rayDist0 - (0.4 - rs * 0.1))) - mask0);
	float shadowMask1 = max(0.0, smoothstep(0.03, 0.0, max(0.0, rayDist1 - (0.4 - rs * 0.1))) - mask1);
	float shadowMask2 = max(0.0, smoothstep(0.03, 0.0, max(0.0, rayDist2 - (0.4 - rs * 0.1))) - mask2);

	float f0 = v0 * step(l0, progress) * mask0;
	float f0S = v0 * step(l0, progress) * shadowMask0;
	float f1 = v1 * step(l1, progress) * mask1;
	float f1S = v1 * step(l1, progress) * shadowMask1;
	float f2 = v2 * step(l2, progress) * mask2;
	float f2S = v2 * step(l2, progress) * shadowMask2;
	
	float v = max(f0, max(f1, f2));
	float vS = max(f0S, max(f1S, f2S));
	vS = lerp(vS, 0.0, f1);
	vS = lerp(vS, 0.0, f2);

	color.rgb = lerp(color.rgb, color.rgb * 0.333, vS);
	color.a = 1.0 - v;
	color.rgb *= color.a;
#elif FADEEFFECT == 18
// Fade to black
	color.rgb *= smoothstep(0.5, 0.0, progress);
	color.a = smoothstep(1.0, 0.5, progress);
#elif FADEEFFECT == 19
// Twister
	float2 delta = texCoord - float2(0.5, 0.5);
	delta.x *= g_AspectRatio;
	float dist = length(delta);
	float smooth = 0.1;
	color.a = 1.0 - smoothstep(0.0, smooth, max(0.0, progress * (1.0 + smooth) - dist));

	delta.x /= g_AspectRatio;
	float smoothTwist = 0.5;
	float twistAmt = smoothstep(0.0, smoothTwist, max(0.0, progress * (1.0 + smoothTwist) - dist));
	delta /= 1.0 + twistAmt;
	texCoord = float2(0.5, 0.5) + rotateFloat2(delta, progress * 20.0 * twistAmt);
	color.rgb = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).rgb;

	color.rgb *= color.a;
#elif FADEEFFECT == 20
// Black hole
	float holeSize = smoothstep(0, 0.8, progress) * smoothstep(1.0, 0.8, progress);
	float noiseAmt = 0.01 * smoothstep(0.95, 0.8, progress);
	float2 noiseOffset = float2(snoise((float2)progress * 100), g_AspectRatio * snoise((float2)(progress * 100 + g_Hash)));
	float2 center = float2(0.5, 0.5) + holeSize * noiseAmt * noiseOffset;
	float2 delta = texCoord - center;

	float dist = length(delta * float2(g_AspectRatio, 1.0));
	float holeAmt = smoothstep(holeSize * 0.05, holeSize * 0.04, dist);

	// Sample distorted frame
	texCoord -= float2(0.5, 0.5);
	float smoothDistort = 1.0;
	float distortAmt = pow(smoothstep(0.0, smoothDistort, max(0.0, (progress * 0.97) * (smoothDistort))), 2.0);
	texCoord *= (1.0 + (1.0 / length(delta)) * distortAmt);

	float angle = progress * 4 * pow(smoothstep(holeSize * 0.2, 0.0, dist), 2.0);
	angle = lerp(angle, -angle, step(0.5, g_Hash));
	texCoord = rotateFloat2(texCoord, angle);

	texCoord += float2(0.5, 0.5);
	color.r = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).r;
	color.g = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord - angle * 0.04, 0.0).g;
	color.b = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord + angle * 0.04, 0.0).b;

	float2 shadowDelta = texCoord - float2(0.5, 0.5);
	float shadowAngle = atan2(shadowDelta.y, -shadowDelta.x);
	float shadowAmt = abs(dot(float2(1.0, 0.0), shadowDelta)) * sin(shadowAngle * 6.0);
	color.rgb = lerp(color.rgb, (float3)0.0, pow(shadowAmt, 2.0) * distortAmt * 4.0);

	color.a = step(0.0, texCoord.x) * step(texCoord.x, 1.0) *
		step(0.0, texCoord.y) * step(texCoord.y, 1.0);
	delta = texCoord - center;
	color.a *= step(dot(delta, delta), 0.5);
	color.a *= step(progress, 0.9);
	color.rgb *= color.a;

	// Apply hole color
	float holeCornea = smoothstep(holeSize * 0.03, holeSize * 0.05, dist);
	float3 colorOuter = color.rgb;
	color.rgb = lerp(color.rgb, (float3)0.0, holeAmt);
	color.rgb = lerp(color.rgb, pow(colorOuter, (float3)2.0), holeAmt * holeCornea);
	color.a = max(color.a, holeAmt);
#elif FADEEFFECT == 21
// CRT
	float2 texCoordOrig = texCoord;
	texCoord -= (float2)0.5;
	texCoord.y *= (1.0 + pow(smoothstep(0.2, 0.6, progress), 2.0) * g_Height * 0.5);
	texCoord.x *= (1.0 - pow(smoothstep(0.05, 0.25, progress), 2.0) * 0.8);
	texCoord.x *= (1.0 + pow(smoothstep(0.4, 0.8, progress), 2.0) * g_Width * 0.25);
	texCoord += (float2)0.5;

	float scroll = smoothstep(0.0, 0.1, progress) * smoothstep(0.2, 0.1, progress) * 0.2;
	scroll -= pow(smoothstep(0.1, 0.4, progress), 1.4) * 5.0;
	float amtGlowWhite = smoothstep(0.1, 0.4, progress);
	float fadeBlack = smoothstep(0.7, 0.81, progress);
	float amtOutsideBounds = saturate(step(texCoord.y, 0.0) + step(1.0, texCoord.y) +
		step(texCoord.x, 0.0) + step(1.0, texCoord.x) +
		fadeBlack);

	float2 texCoordPreScroll = texCoord;
	texCoord.y = frac(texCoord.y + scroll);
	float chroma = pow(smoothstep(0.07, 0.2, progress), 2.0);
	float chromaMax = 0.04; //0.02;
	float mip = smoothstep(0.1, 0.3, progress) * 4.0;
	color.rgb = float3(g_Texture0MipMapped.SampleLevel(g_Texture0SamplerState, texCoord, mip).r,
			g_Texture0MipMapped.SampleLevel(g_Texture0SamplerState, texCoord + float2(0, chromaMax * chroma), mip).g,
			g_Texture0MipMapped.SampleLevel(g_Texture0SamplerState, texCoord + float2(0, -chromaMax * chroma), mip).b);
	color.a = smoothstep(1.0, 0.7, progress);

	float smoothFade = 15.0;
	float amtOutsideGlow = amtOutsideBounds * (smoothstep(smoothFade, 1.0, texCoordPreScroll.y) * smoothstep(-smoothFade, 0.0, texCoordPreScroll.y));
	amtOutsideGlow *= smoothstep(smoothFade, 1.0, texCoordPreScroll.x) * smoothstep(-smoothFade, 0.0, texCoordPreScroll.x);
	amtOutsideGlow = pow(amtOutsideGlow, 4.0);

	float3 outsideColor = snoise(float3(texCoordOrig * float2(g_AspectRatio, 1.0) * 100.0, progress * 10.0));
	outsideColor = smoothstep((float3)-1.0, (float3)1.0, outsideColor) * smoothstep(0.5, 0.4, progress) * 0.1 *
		smoothstep(0.5, 0.0, abs(texCoordOrig.y - 0.5));

	color.rgb = lerp(color.rgb, (float3)0.666, amtGlowWhite);
	color.rgb = lerp(color.rgb, outsideColor, amtOutsideBounds);
	color.rgb = lerp(color.rgb, float3(0.25, 0.27, 0.33), amtOutsideGlow * (1.0 - fadeBlack));
	color.rgb *= color.a;

	//color = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoordOrig, 4.0);
#elif FADEEFFECT == 22
// Radial wipe
	float2 delta = texCoord - float2(0.5, 0.5);
	float angle = (atan2(-delta.x, delta.y) + 3.141) / 6.283;
	float smooth = 0.02;
	float shadowSmooth = 0.1;

	progress *= 1.0 + smooth;
	color.a = smoothstep(progress - smooth, progress, angle);
	color.rgb *= color.a;
#elif FADEEFFECT == 23
// Glass shatter
	color.r = g_Texture0.SampleLevel(g_Texture0SamplerState, frac(texCoord), 0.0).r;
	color.g = g_Texture0.SampleLevel(g_Texture0SamplerState, frac(IN.v_TexCoordBase), 0.0).g;
	color.b = g_Texture0.SampleLevel(g_Texture0SamplerState, frac(texCoord - (IN.v_TexCoordBase - texCoord)), 0.0).b;

	float3 lightDir = float3(0.707, -0.707, 0.0);
	float3 worldNormal = normalize(IN.v_WorldNormal);
	float3 eyeVector = float3(0, 0, 0) - IN.v_WorldPos;
	float specular = max(0.0, dot(normalize(eyeVector + lightDir), worldNormal));
	specular = pow(specular, 4.0);

	float light = dot(lightDir, worldNormal) + 1.0;
	light = pow(light, 1.0);
	color.rgb *= light;
	color.rgb += (float3)specular * 2.0;
	
	color.a = smoothstep(1.0, 0.9, g_Progress);
	color.rgb *= color.a;
#elif FADEEFFECT == 24
// Bullets
	float2 center = float2(0.25 + 0.5 * g_Hash, 0.25 + 0.5 * g_Hash2);
	
	float shakeTimer = smoothstep(0.05, 0.2, progress);
	float shakeTimerOct = smoothstep(0.05, 0.5, progress);
	float motionTimer = smoothstep(0.4, 1.0, progress);
	float impactTimer = smoothstep(0.0, 0.1, progress);
	float blackBlendTimer = smoothstep(0.8, 0.7, progress);
	float alphaTimer = smoothstep(1.0, 0.9, progress);
	float shakeTranslationBlend = smoothstep(0.05, 0.1, progress) * smoothstep(0.4, 0.05, progress) + smoothstep(0.6, 0.8, progress) * smoothstep(0.9, 0.8, progress);
	
	shakeTimerOct = pow(shakeTimerOct, 0.2);
	
	float2 zoomDelta = texCoord - center;
	float2 zoomDeltaReference = zoomDelta;
	zoomDelta.x *= g_AspectRatio;
	zoomDelta = rotateFloat2(zoomDelta, shakeTimerOct * 0.4 * g_Hash2 * lerp(1,-1,step(0.5, g_Hash)) + shakeTimer * (1.0 - shakeTimer) * 0.3 * sin(shakeTimer * 4));
	zoomDelta.x /= g_AspectRatio;
	
	float2 shakeNoise = float2(snoise(float2(progress * 10.0, 0.0)), snoise(float2(progress * 10.0, 10.0))) * 0.02 * shakeTranslationBlend;
	zoomDelta *= 1.0 - motionTimer;
	zoomDelta *= 1.0 - shakeTimerOct * 0.05;
	zoomDelta += shakeNoise;
	
	zoomDeltaReference *= 1.0 - motionTimer;
	zoomDeltaReference *= 1.0 - shakeTimerOct * 0.05;
	zoomDeltaReference += shakeNoise;
	float2 centerMotion = (center - float2(0.5, 0.5)) * (motionTimer) * (1.0 - motionTimer);
	texCoord = center + zoomDelta + centerMotion;
	float2 texCoordUnrotated = center + zoomDeltaReference + centerMotion;

	float2 texCoordSkewed = texCoord;
	texCoordSkewed = texCoordSkewed * (fbm(texCoord * float2(g_AspectRatio, 1.0) * 7.0 + g_Hash, 4) * 0.02 + 1.0);
	
	float2 delta = texCoordSkewed - center;
	delta.x *= g_AspectRatio;
	
	float distance = length(delta);
	float distanceOriginal = distance;
	distance = pow(distance, 0.3);
	float angle = atan2(delta.x, -delta.y) + g_Hash * 99;

	float y = distance * 10.0;

	angle = angle * 10.0;
	float testOffset1 = snoise(float2(floor(angle), y * 0.4));
	float testOffset2 = snoise(float2(floor(angle) + 1.0, y * 0.4));
	float testOffset = lerp(testOffset1, testOffset2, frac(angle));

	float blend1 = snoise(float2(floor(angle), 0.0));
	float blend2 = snoise(float2(floor(angle) + 1.0, 0.0));
	float blend = lerp(blend1, blend2, frac(angle));
	blend = smoothstep(0.5, 0.2, blend);

	float patternDistance = pow(max(0.0, distance - 0.25), 0.1) * 3.0;
	float test = sin(patternDistance * 40.0 + testOffset * distance * 2.0);
	float origFlow = test;
	test = abs(test);
	test = pow(test, 8.0 + 10.0 * testOffset);
	test = smoothstep(0.0, 0.2 + 0.8 * testOffset, test);

	float baseOpacity = smoothstep(0.01, 0.017, distanceOriginal) *
			smoothstep(0.2, 0.01, distanceOriginal);
	baseOpacity = pow(baseOpacity, 4.0) * impactTimer;

	// Fade out
	blend *= smoothstep(0.6 * impactTimer, 0.3 * impactTimer, distance - saturate(1.0 - testOffset) * 0.2);

	// Fade in
	blend *= smoothstep(0.25, 0.3, distance);
	
	baseOpacity *= 1.0 - snoise(texCoordSkewed * 10.0 + g_Hash) * (1.0 - abs(origFlow * 2.0 - 1.0)) * 2;

	float gradx = ddx(test + testOffset);
	float grady = ddy(test + testOffset);

	float r = fbm(float2(angle * 0.3, y * 0.4), 3);
	r = smoothstep(-0.5, 0.5, r);
	
	float blackCenter = smoothstep(0.017, 0.01, distanceOriginal) * impactTimer;
	color.a = alphaTimer * lerp(1.0, blackBlendTimer, blackCenter);

	color.rgb = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord + float2(gradx, -grady) * blend, 0.0).rgb;
	color.rgb = lerp(color.rgb, (0.7 + r) * float3(0.8, 0.85, 1.0), (pow(test * blend * r, 2.0) + baseOpacity - blend * (abs(gradx) - abs(grady))));
	color.rgb = lerp(color.rgb, (float3)0.0, blackCenter);
	
	float2 flareDelta = texCoordUnrotated - center;
	flareDelta.x *= g_AspectRatio;
	float flareTimerFade = smoothstep(0.0, 0.1, progress);
	flareDelta.x *= pow(flareTimerFade, 0.1);
	flareTimerFade = flareTimerFade * (1.0 - flareTimerFade);
	flareDelta.y /= pow(flareTimerFade, 0.5) + 0.00001;
	float flare = 1.0 - length(flareDelta);
	flare *= flareTimerFade;
	flare = saturate(flare);
	flare = pow(flare * 4.0, 2.0);
	color.rgb *= (float3)(1.0) + flare * float3(1.0, 0.7, 0.2);

	color.rgb *= color.a;
#elif FADEEFFECT == 25
// Ice
	float freezeOutTimer = pow(smoothstep(1.0, 0.5, progress), 2);
	float freezeTimer = (smoothstep(0.0, 0.2, progress) * 0.333 + smoothstep(0.25, 0.5, progress) * 0.667) * freezeOutTimer;
	float fadeTimer = smoothstep(1.0, 0.95, progress);

	float2 center = (float2)0.5;
	float2 delta = texCoord - center;
	delta.x *= g_AspectRatio;
	float distance = length(delta) / max(g_AspectRatio, 1.0);

	float noise = fbm(texCoord * float2(g_AspectRatio, 1.0) * 2.0 + g_Hash, 8) * 0.5 + 0.5;
	float rift = fbm(texCoord * float2(g_AspectRatio, 1.0) * 3.0 + g_Hash2, 8) * 0.5 + 0.5;
	rift = smoothstep(0.4, 0.5, rift) * smoothstep(0.55, 0.5, rift);
	
	float blendTransition = 0.3;
	float blendDistance = 0.9 - distance;
	noise *= blendTransition + progress * 0.2 + smoothstep(0.3, 0.4, progress) * 0.1 + smoothstep(0.5, 0.6, progress) * 0.1;
	noise *= 1.0 + rift * (0.5 + 0.5 * progress) * 0.05;
	
	float blendNoise = noise + rift * 0.1;
	float blend = smoothstep(blendDistance - blendNoise * 0.51, blendDistance - blendNoise * 0.5, freezeTimer * (1.0 + blendTransition));

	float mip = blend * 3.0 + blend * rift * 3.0;
	float2 texCoordOffset = float2(ddx(noise), ddy(noise)) * 100.0;
	texCoordOffset = pow(abs(texCoordOffset), 2.0) * sign(texCoordOffset);
	texCoord += texCoordOffset * blend;
	color.rgb = g_Texture0MipMapped.SampleLevel(g_Texture0SamplerState, texCoord, mip).rgb;
	color.rgb *= 1.0 + length(texCoordOffset) * 3.0 * blend;
	color.rgb += float3(0.6, 0.65, 1.0) * blend * noise * 4.0 * pow(distance + rift * 0.1, 2.0);

	texCoord += texCoordOffset * blend * 2.0;
	float flashLine = smoothstep(progress - 0.4, progress - 0.27, texCoord.x * 0.1 + 0.2 - texCoord.y * 0.005);
	flashLine = flashLine * (1.0 - flashLine) * 2.0;
	float flashVert = abs(texCoord.y * 2.0 - 1.0);
	flashLine *= flashVert;
	float flashBlend = flashLine;
	color.rgb += color.rgb * flashBlend * blend;

	color.a = max(blend, step(0.99, freezeOutTimer)) * fadeTimer;
	color.rgb *= color.a;
#elif FADEEFFECT == 26
// Boilover
	//color = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0);
	color.a = 1.0;
	float blendRipple = smoothstep(0.0, 0.1, progress);
	float blendUpscale = pow(smoothstep(0.8, 1.0, progress), 2.0);
	float light = 1.0;
	
	for (int i = 0; i < 25; ++i)
	{
		//float2 centerOffset = float2(snoise(float2(i + g_Hash * 99, i * 99 + g_Hash2 * 33)),
		//	snoise(float2(i * 17 + g_Hash * 71, i * 22 + g_Hash2 * 17)));
		float3 sharedNoise = g_Texture1Noise.SampleLevel(g_Texture0SamplerStateWrap, float2(i / 25.0 + g_Hash, i / 25.0 + g_Hash2), 0.0).rgb;
		float2 centerOffset = sharedNoise.rg * 2.0 - 1.0;
		float2 center = float2(0.5, 0.5) + centerOffset * 0.55;
		
		//float maxDist = 0.1 + (fbm(center * 99, 2) * 0.5 + 0.5) * 0.33 * progress + 0.5 * blendUpscale;
		float maxDist = 0.1 + (g_Texture2Clouds.SampleLevel(g_Texture0SamplerStateWrap, center * 99, 0.0).r) * 0.33 * progress + 0.5 * blendUpscale;
		//float timerOffset = (snoise(float2(i + g_Hash * 54, i * 41 + g_Hash2 * 87)) * 0.5 + 0.5) * 0.9;
		float timerOffset = sharedNoise.b * 0.9;
		float animTimer = smoothstep(timerOffset, timerOffset + 0.0001 + 0.5 * smoothstep(1.0, 0.9, progress), progress);
		animTimer = pow(animTimer, 2.0);
		
		float2 delta = texCoord - center;
		float2 deltaRef = delta;
		delta.x *= g_AspectRatio;
		float distance = length(delta);
		
		float rippleTimer = smoothstep(timerOffset - 0.5, timerOffset + 0.5, progress);
		float ripplePos = distance;
		ripplePos = smoothstep(ripplePos, ripplePos + 0.1, rippleTimer) *
			smoothstep(ripplePos + 0.2, ripplePos + 0.1, rippleTimer);
			
		float2 rippleOffset = normalize(deltaRef) * -0.01 * ripplePos * blendRipple;
		
		float test = smoothstep(maxDist, 0.0, distance);
		float anim = test * animTimer * 20.0;
		
		float angle = atan2(deltaRef.x, -deltaRef.y);
		float mask = g_Texture2Clouds.SampleLevel(g_Texture0SamplerStateWrap, float2(angle * 0.25, (anim + progress) * 0.1), 0.0).r;
		//float mask = fbm(float2(angle, anim + progress * 5.0), 3) * 0.5 + 0.5;
		color.a *= step(anim, mask * 2.0);
		
		delta *= saturate(1.0 - anim);
		delta.x /= g_AspectRatio;
		float2 uvOffset = delta - deltaRef + rippleOffset;
		texCoord += uvOffset;
		
		light += dot(normalize(float3(uvOffset, 1.0)), float3(-0.707, 0.707, 0.0)) * 10;
	}
	
	color.a *= smoothstep(1.0, 0.9, progress);
	
	color.rgb = g_Texture0.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).rgb * light;
	//color.rgb = g_Texture2Clouds.SampleLevel(g_Texture0SamplerState, texCoord, 0.0).rgb;
	color.rgb *= color.a;
#endif
	return color;
}

PS_OUTPUT main(VS_OUTPUT IN)
{
	PS_OUTPUT OUT;
	OUT.p_FragColor = PerformEffect(IN, IN.v_TexCoord, g_Progress);
	return OUT;
}
