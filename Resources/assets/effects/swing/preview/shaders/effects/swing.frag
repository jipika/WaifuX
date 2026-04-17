
// [COMBO] {"material":"ui_editor_properties_double_sided","combo":"DOUBLESIDED","type":"options","default":0}

varying vec2 v_TexCoord;
varying vec2 v_TexCoordMask;

uniform vec4 g_Texture0Resolution;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}

uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0.25 0.5"}
uniform vec2 g_Point1; // {"material":"point1","label":"p1","default":"0.75 0.5"}
uniform float g_Size; // {"material":"size","label":"ui_editor_properties_size","default":0.4,"range":[0,1]}
uniform float g_CenterPos; // {"material":"center","label":"ui_editor_properties_center","default":0.5,"range":[0,1]}
uniform float g_Feather; // {"material":"feather","label":"ui_editor_properties_feather","default":0.01,"range":[0,0.2]}

uniform float g_Speed; // {"material":"speed","label":"ui_editor_properties_speed","default":2.0,"range":[-5,5]}
uniform float g_Amount; // {"material":"amount","label":"ui_editor_properties_amount","default":0.2,"range":[0,1]}

uniform float g_Time;

void main() {
	vec2 texCoord = v_TexCoord.xy;

	//gl_FragColor = mix(texSample2D(g_Texture0, v_TexCoord.zw), gl_FragColor, mask);


	float aspect = g_Texture0Resolution.x / g_Texture0Resolution.y;
	vec2 p0 = g_Point0;
	vec2 p1 = g_Point1;
	
	p0.x *= aspect;
	p1.x *= aspect;
	texCoord.x *= aspect;
	
	vec2 axis = normalize(p1 - p0);
	vec2 center = p0 + (p1 - p0) * g_CenterPos;
	float distortAmt = g_Amount;
	float speed = g_Speed;
	
	//distortAmt *= sin(g_Time * speed);
	//
	//mat3 xform = inverse(squareToQuad(vec2(0, 0) - vec2(distortAmt, distortAmt),
	//	vec2(1, 0) + vec2(-distortAmt, distortAmt),
	//	vec2(1, 1) + vec2(-distortAmt, -distortAmt),
	//	vec2(0, 1) - vec2(distortAmt, -distortAmt)
	//));
	//
	//vec3 puvs = mul(vec3(texCoord, 1.0), xform);
	//
	//texCoord = puvs.xy / puvs.z;

	//axis.x *= aspect;
	axis = normalize(axis);
	vec2 axisOrtho = vec2(-axis.y, axis.x);
	vec2 uvDelta = texCoord - center;
	
	float distanceAlongAxis = dot(axis, uvDelta);
	float distanceOrtho = dot(axisOrtho, uvDelta);


	float anim = sin(g_Time * speed);
	distortAmt *= anim;
	vec2 uvDistort = axis * distortAmt * distanceOrtho * distanceAlongAxis;
	uvDistort += axisOrtho * distortAmt * anim * distanceOrtho;
	//uvDistort.x /= aspect;
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
