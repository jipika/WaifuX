
// [COMBO] {"material":"ui_editor_properties_double_sided","combo":"DOUBLESIDED","type":"options","default":0}
// [COMBO] {"material":"ui_editor_properties_noise","combo":"NOISE","type":"options","default":0}

varying vec4 v_TexCoord;
varying vec2 v_TexCoordMask;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_noise","default":"util/noise"}

uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0.25 0.5"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"0.75 0.5"}
uniform float g_Size; // {"material":"size","label":"ui_editor_properties_size","default":0.4,"range":[0,1]}
uniform float g_CenterPos; // {"material":"center","label":"ui_editor_properties_center","default":0.5,"range":[0,1]}
uniform float g_Feather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.01,"range":[0,0.2]}

uniform float g_Amount; // {"material":"amount","label":"ui_editor_properties_amount","default":0.2,"range":[0,1]}

uniform float g_Time;

uniform float g_NoiseSpeed; // {"material":"noisespeed","label":"ui_editor_properties_noise_speed","default":0.15,"range":[0,0.2]}
uniform float g_NoiseAmount; // {"material":"noiseamount","label":"ui_editor_properties_noise_amount","default":0.2,"range":[0,1]}

void main() {
	vec2 texCoord = v_TexCoord.xy;

	float aspect = v_TexCoord.z;
	vec2 p0 = g_Point0;
	vec2 p1 = g_Point1;
	
	p0.x *= aspect;
	p1.x *= aspect;
	texCoord.x *= aspect;
	
	vec2 axis = normalize(p1 - p0);
	vec2 center = p0 + (p1 - p0) * g_CenterPos;

	//axis.x *= aspect;
	axis = normalize(axis);
	vec2 axisOrtho = vec2(-axis.y, axis.x);
	vec2 uvDelta = texCoord - center;
	
	float distanceAlongAxis = dot(axis, uvDelta);
	float distanceOrtho = dot(axisOrtho, uvDelta);

	float anim = v_TexCoord.w;
	
#if NOISE
	float noise = texSample2D(g_Texture2, vec2(g_Time * 0.08333333, g_Time * 0.02777777) * g_NoiseSpeed).r * 3.141 * 2.0;
	anim = clamp(anim + sin(noise) * g_NoiseAmount, -1.0, 1.0);
#endif
	
	float distortAmt = anim;
	vec2 uvDistort = axis * distortAmt * distanceOrtho * distanceAlongAxis;
	uvDistort += axisOrtho * distortAmt * anim * distanceOrtho;
	texCoord += uvDistort;

	// software mask area
	float mask = 1.0;
	float feather = max(g_Feather, 0.00001);
	
	vec2 deltaRight = texCoord - p1;
	vec2 deltaLeft = texCoord - p0;
	float distanceRight = dot(deltaRight, axis);
	float distanceLeft = dot(deltaLeft, axis);
	
	// Clip to right
	mask *= smoothstep(feather, 0, distanceRight);
	mask *= smoothstep(-feather, 0, distanceLeft);
	
	float sizeMod = g_Size;
	sizeMod = g_Size * (1.0 - abs(anim) * g_Amount * 0.5);
	
	// Feather bottom page
	mask *= smoothstep(sizeMod + feather, sizeMod - feather, distanceOrtho);
	
#if DOUBLESIDED
	// Feather top page
	mask *= smoothstep(sizeMod + feather, sizeMod - feather, -distanceOrtho);
#else
	// Clip to bottom page
	mask *= step(0, distanceOrtho);
#endif

#if MASK
	mask *= texSample2D(g_Texture1, v_TexCoordMask).r;
#endif

	texCoord.x /= aspect;
	texCoord = mix(v_TexCoord.xy, texCoord, mask);
	gl_FragColor = texSample2D(g_Texture0, texCoord);
}
