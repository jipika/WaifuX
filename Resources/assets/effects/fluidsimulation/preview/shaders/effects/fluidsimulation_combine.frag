
// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31}
// [COMBO] {"material":"ui_editor_properties_rendering","combo":"RENDERING","type":"options","default":0,"options":{"ui_editor_properties_gradient":0,"ui_editor_properties_emitter_color":1,"ui_editor_properties_background_color":2,"ui_editor_properties_distortion":3}}
// [COMBO] {"material":"ui_editor_properties_opaque_background","combo":"OPAQUE","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_write_alpha","combo":"WRITEALPHA","type":"options","default":1}

#include "common_pbr.h"
#include "common_blending.h"

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
uniform sampler2D g_Texture2; // {"hidden":true}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_gradient_map","default":"gradient/gradient_fire","require":{"RENDERING":0}}
uniform sampler2D g_Texture4; // {"hidden":true}

uniform float u_Brightness; // {"material":"brightness","label":"ui_editor_properties_brightness","default":1.0,"range":[0.01, 5]}
uniform float u_Alpha; // {"material":"opacity","label":"ui_editor_properties_opacity","default":1.0,"range":[0.01, 1]}
uniform float u_Feather; // {"material":"feather","label":"ui_editor_properties_feather","default":1.0,"range":[0.01, 1]}
uniform float u_HueShift; // {"material":"hue","label":"ui_editor_properties_hue","default":0.0,"range":[0.0, 1.0]}

varying vec2 v_TexCoord;

uniform vec4 g_Texture0Resolution;
uniform vec4 g_Texture1Resolution;

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

#if LIGHTING
uniform float u_Roughness; // {"material":"roughness","label":"ui_editor_properties_roughness","default":0.5,"range":[0,1],"group":"ui_editor_properties_material"}
uniform float u_Metallic; // {"material":"metallic","label":"ui_editor_properties_metallic","default":0.5,"range":[0,1],"group":"ui_editor_properties_material"}

uniform vec4 g_LightsColorPremultiplied[3];
uniform vec3 g_LightAmbientColor;

varying vec4 v_Light0DirectionL3X;
varying vec4 v_Light1DirectionL3Y;
varying vec4 v_Light2DirectionL3Z;
#endif

void main() {
	vec2 fxCoords = v_TexCoord.xy;
	float fxMask = 1.0;
	
#if PERSPECTIVE == 1
	fxCoords = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
	fxMask *= step(abs(fxCoords.x - 0.5), 0.5);
	fxMask *= step(abs(fxCoords.y - 0.5), 0.5);
#endif

	vec4 albedo = texSample2D(g_Texture0, fxCoords.xy);
	float refAlpha = albedo.a;

#if RENDERING == 0
	vec4 gradientColor = texSample2D(g_Texture3, vec2(albedo.r, 0.5));
	vec3 hsv = rgb2hsv(gradientColor.rgb);
	hsv.x += u_HueShift;
	albedo.rgb = hsv2rgb(hsv) * u_Brightness;
	albedo.a *= gradientColor.a;
#endif

#if RENDERING == 1
	albedo.rgb *= u_Brightness;
#endif

#if RENDERING == 2
	albedo.rgb *= u_Brightness;
	albedo.rgb /= albedo.a + 0.00001;
#endif

	albedo.a = smoothstep(0.0, u_Feather, albedo.a);

#if RENDERING == 3
#if LIGHTING
	vec2 velocity = texSample2D(g_Texture2, fxCoords.xy).xy * CAST2(2.0) - CAST2(1.0);
#else
	float pressure = texSample2D(g_Texture4, fxCoords.xy).x;
	vec2 velocity = vec2(ddx(pressure), ddy(pressure));
	velocity = sign(velocity) * smoothstep(CAST2(0.01), CAST2(10.0), abs(velocity));
#endif

	vec2 uvOffset = velocity;
	vec4 prevDistorted = texSample2D(g_Texture1, v_TexCoord.xy - uvOffset);
	albedo.rgb = prevDistorted.rgb;
	albedo.a = 1;
#endif

	albedo.a *= fxMask;

#if LIGHTING
	vec3 normal = normalize(texSample2D(g_Texture2, fxCoords.xy).rgb * CAST3(2.0) - CAST3(1.0));

	float metallic = u_Metallic;
	float roughness = u_Roughness;

	vec3 f0 = CAST3(0.04);
	f0 = mix(f0, albedo.rgb, metallic);
	vec3 normalizedViewVector = vec3(0, 0, 1);
	
	vec3 light = ComputePBRLight(normal, v_Light0DirectionL3X.xyz, normalizedViewVector, albedo.rgb, g_LightsColorPremultiplied[0].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, v_Light1DirectionL3Y.xyz, normalizedViewVector, albedo.rgb, g_LightsColorPremultiplied[1].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, v_Light2DirectionL3Z.xyz, normalizedViewVector, albedo.rgb, g_LightsColorPremultiplied[2].rgb, f0, roughness, metallic);
	light += ComputePBRLight(normal, vec3(v_Light0DirectionL3X.w, v_Light1DirectionL3Y.w, v_Light2DirectionL3Z.w),
		normalizedViewVector, albedo.rgb,
		vec3(g_LightsColorPremultiplied[0].w, g_LightsColorPremultiplied[1].w, g_LightsColorPremultiplied[2].w),
		f0, roughness, metallic);
	vec3 ambient = max(CAST3(0.001), g_LightAmbientColor) * albedo.rgb;

	albedo.rgb = CombineLighting(light, ambient);
#endif

#if OPAQUE
	albedo.a = 1;
#else
	vec4 prev = texSample2D(g_Texture1, v_TexCoord.xy);
#if BLENDMODE == 0
	albedo = mix(prev, albedo, saturate(albedo.a) * u_Alpha);
#else
	albedo.rgb = ApplyBlending(BLENDMODE, prev.rgb, albedo.rgb, albedo.a * u_Alpha);
#endif
	albedo.a = saturate(prev.a + albedo.a);
#if WRITEALPHA == 0
	albedo.a = prev.a;
#endif
#endif

	gl_FragColor = albedo;
}
