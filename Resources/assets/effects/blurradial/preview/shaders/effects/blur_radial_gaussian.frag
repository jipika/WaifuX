
// [COMBO] {"material":"ui_editor_properties_blur_alpha","combo":"BLURALPHA","type":"options","default":1}

#include "common.h"
#include "common_blur.h"

varying vec2 v_TexCoord;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform float u_Scale; // {"default":1,"label":"ui_editor_properties_scale","material":"scale","range":[0.01,2.0]}
uniform vec2 u_Center; // {"material":"ui_editor_properties_center","position":true,"default":"0.5 0.5"}

#if MASK
varying vec2 v_TexCoordMask;
#endif

vec4 blurRadial13a(vec2 u, float amt)
{
	vec2 center = u_Center;
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = 1.4091998770852122 * amt;
	float o2 = 3.2979348079914822 * amt;
	float o3 = 5.2062900776825969 * amt;
	vec2 r1 = rotateVec2(delta, o1) - delta;
	vec2 r2 = rotateVec2(delta, o2) - delta;
	vec2 r3 = rotateVec2(delta, o3) - delta;
	return texSample2D(g_Texture0, u) * 0.1976406528809576
	+ texSample2D(g_Texture0, center + r1 + delta) * 0.2959855056006557
	+ texSample2D(g_Texture0, center - r1 + delta) * 0.2959855056006557
	+ texSample2D(g_Texture0, center + r2 + delta) * 0.0935333619980593
	+ texSample2D(g_Texture0, center - r2 + delta) * 0.0935333619980593
	+ texSample2D(g_Texture0, center + r3 + delta) * 0.0116608059608062
	+ texSample2D(g_Texture0, center - r3 + delta) * 0.0116608059608062;
}

vec4 blurRadial7a(vec2 u, float amt)
{
	vec2 center = u_Center;
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = 2.3515644035337887 * amt;
	float o2 = 0.469433779698372 * amt;
	float o3 = 1.4091998770852121 * amt;
	float o4 = 3 * amt;
	vec2 r1 = rotateVec2(delta, o1) - delta;
	vec2 r2 = rotateVec2(delta, o2) - delta;
	vec2 r3 = rotateVec2(delta, -o3) - delta;
	vec2 r4 = rotateVec2(delta, -o4) - delta;

	return texSample2D(g_Texture0, center + r1 + delta) * 0.2028175528299753
	+ texSample2D(g_Texture0, center + r2 + delta) * 0.4044856614512112
	+ texSample2D(g_Texture0, center + r3 + delta) * 0.3213933537319605
	+ texSample2D(g_Texture0, center + r4 + delta) * 0.0713034319868530;
}

vec4 blurRadial3a(vec2 u, float amt)
{
	vec2 center = u_Center;
	vec2 delta = u - center;
	amt = amt * 0.025;
	float o1 = amt;
	vec2 r1 = rotateVec2(delta, o1) - delta;

	return texSample2D(g_Texture0, center + delta) * 0.5
	+ texSample2D(g_Texture0, center + r1 + delta) * 0.25
	+ texSample2D(g_Texture0, center - r1 + delta) * 0.25;
}

void main() {
#if KERNEL == 0
	vec4 albedo = blurRadial13a(v_TexCoord.xy, u_Scale);
#endif
#if KERNEL == 1
	vec4 albedo = blurRadial7a(v_TexCoord.xy, u_Scale);
#endif
#if KERNEL == 2
	vec4 albedo = blurRadial3a(v_TexCoord.xy, u_Scale);
#endif

#if MASK || BLURALPHA == 0
	vec4 prev = texSample2D(g_Texture0, v_TexCoord.xy);
#endif

#if MASK
	albedo = mix(prev, albedo, texSample2D(g_Texture1, v_TexCoordMask.xy).r);
#endif

#if BLURALPHA == 0
	albedo.a = prev.a;
#endif

	gl_FragColor = albedo;
}
