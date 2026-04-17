vec3 blur13(vec2 u, vec2 d)
{
	vec2 o1 = CAST2(1.4091998770852122) * d;
	vec2 o2 = CAST2(3.2979348079914822) * d;
	vec2 o3 = CAST2(5.2062900776825969) * d;
	return texSample2D(g_Texture0, u).rgb * 0.1976406528809576
	+ texSample2D(g_Texture0, u + o1).rgb * 0.2959855056006557
	+ texSample2D(g_Texture0, u - o1).rgb * 0.2959855056006557
	+ texSample2D(g_Texture0, u + o2).rgb * 0.0935333619980593
	+ texSample2D(g_Texture0, u - o2).rgb * 0.0935333619980593
	+ texSample2D(g_Texture0, u + o3).rgb * 0.0116608059608062
	+ texSample2D(g_Texture0, u - o3).rgb * 0.0116608059608062;
}
vec3 blur7(vec2 u, vec2 d)
{
	vec2 o1 = CAST2(2.3515644035337887) * d;
	vec2 o2 = CAST2(0.469433779698372) * d;
	vec2 o3 = CAST2(1.4091998770852121) * d;
	vec2 o4 = CAST2(3) * d;
	return texSample2D(g_Texture0, u + o1).rgb * 0.2028175528299753
	+ texSample2D(g_Texture0, u + o2).rgb * 0.4044856614512112
	+ texSample2D(g_Texture0, u - o3).rgb * 0.3213933537319605
	+ texSample2D(g_Texture0, u - o4).rgb * 0.0713034319868530;
}
vec3 blur3(vec2 u, vec2 d)
{
	return texSample2D(g_Texture0, u + d).rgb * 0.25
	+ texSample2D(g_Texture0, u).rgb * 0.5
	+ texSample2D(g_Texture0, u - d).rgb * 0.25;
}
vec4 blur13a(vec2 u, vec2 d)
{
	vec2 o1 = CAST2(1.4091998770852122) * d;
	vec2 o2 = CAST2(3.2979348079914822) * d;
	vec2 o3 = CAST2(5.2062900776825969) * d;
	return texSample2D(g_Texture0, u) * 0.1976406528809576
	+ texSample2D(g_Texture0, u + o1) * 0.2959855056006557
	+ texSample2D(g_Texture0, u - o1) * 0.2959855056006557
	+ texSample2D(g_Texture0, u + o2) * 0.0935333619980593
	+ texSample2D(g_Texture0, u - o2) * 0.0935333619980593
	+ texSample2D(g_Texture0, u + o3) * 0.0116608059608062
	+ texSample2D(g_Texture0, u - o3) * 0.0116608059608062;
}
vec4 blur7a(vec2 u, vec2 d)
{
	vec2 o1 = CAST2(2.3515644035337887) * d;
	vec2 o2 = CAST2(0.469433779698372) * d;
	vec2 o3 = CAST2(1.4091998770852121) * d;
	vec2 o4 = CAST2(3) * d;
	return texSample2D(g_Texture0, u + o1) * 0.2028175528299753
	+ texSample2D(g_Texture0, u + o2) * 0.4044856614512112
	+ texSample2D(g_Texture0, u - o3) * 0.3213933537319605
	+ texSample2D(g_Texture0, u - o4) * 0.0713034319868530;
}
vec4 blur3a(vec2 u, vec2 d)
{
	return texSample2D(g_Texture0, u + d) * 0.25
	+ texSample2D(g_Texture0, u) * 0.5
	+ texSample2D(g_Texture0, u - d) * 0.25;
}
vec2 blurRotateVec2(vec2 v, float r)
{
	vec2 cs = vec2(cos(r), sin(r));
	return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
}
vec4 blurRadial13a(vec2 u, vec2 center, float amt)
{
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = 1.4091998770852122 * amt;
	float o2 = 3.2979348079914822 * amt;
	float o3 = 5.2062900776825969 * amt;
	vec2 r1 = blurRotateVec2(delta, o1) - delta;
	vec2 r2 = blurRotateVec2(delta, o2) - delta;
	vec2 r3 = blurRotateVec2(delta, o3) - delta;
	return texSample2D(g_Texture0, u) * 0.1976406528809576
	+ texSample2D(g_Texture0, center + r1 + delta) * 0.2959855056006557
	+ texSample2D(g_Texture0, center - r1 + delta) * 0.2959855056006557
	+ texSample2D(g_Texture0, center + r2 + delta) * 0.0935333619980593
	+ texSample2D(g_Texture0, center - r2 + delta) * 0.0935333619980593
	+ texSample2D(g_Texture0, center + r3 + delta) * 0.0116608059608062
	+ texSample2D(g_Texture0, center - r3 + delta) * 0.0116608059608062;
}
vec4 blurRadial7a(vec2 u, vec2 center, float amt)
{
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = 2.3515644035337887 * amt;
	float o2 = 0.469433779698372 * amt;
	float o3 = 1.4091998770852121 * amt;
	float o4 = 3 * amt;
	vec2 r1 = blurRotateVec2(delta, o1) - delta;
	vec2 r2 = blurRotateVec2(delta, o2) - delta;
	vec2 r3 = blurRotateVec2(delta, -o3) - delta;
	vec2 r4 = blurRotateVec2(delta, -o4) - delta;

	return texSample2D(g_Texture0, center + r1 + delta) * 0.2028175528299753
	+ texSample2D(g_Texture0, center + r2 + delta) * 0.4044856614512112
	+ texSample2D(g_Texture0, center + r3 + delta) * 0.3213933537319605
	+ texSample2D(g_Texture0, center + r4 + delta) * 0.0713034319868530;
}
vec4 blurRadial3a(vec2 u, vec2 center, float amt)
{
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = amt;
	vec2 r1 = blurRotateVec2(delta, o1) - delta;

	return texSample2D(g_Texture0, center + delta) * 0.5
	+ texSample2D(g_Texture0, center + r1 + delta) * 0.25
	+ texSample2D(g_Texture0, center - r1 + delta) * 0.25;
}