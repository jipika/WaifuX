
varying vec2 v_TexCoord;

uniform float g_Frametime;
uniform vec4 g_PointerState;
uniform sampler2D g_Texture0; // {"hidden":true}

varying vec4 v_PointerUV;
varying vec4 v_PointerUVLast;
varying vec2 v_PointDelta;

#if PERSPECTIVE == 1
//varying mat3 v_XForm;
#endif

void main() {

	vec2 texSource = v_TexCoord.xy;

	vec4 albedo = texSample2D(g_Texture0, texSource);

	// Complete unproject per pixel
	vec2 unprojectedUVs = v_PointerUV.xy;
	vec2 unprojectedUVsLast = v_PointerUVLast.xy;
	
	//vec2 pointerDebug;
	//pointerDebug = unprojectedUVs;
	//unprojectedUVs += 0.5;
	//unprojectedUVs.y = 1.0 - unprojectedUVs.y;
	//unprojectedUVsLast += 0.5;
	//unprojectedUVsLast.y = 1.0 - unprojectedUVsLast.y;
	
	float rippleMask = 1.0;
	
#if PERSPECTIVE == 1
	// This perspective transform will take the cursor within the gizmo boundaries and
	// map it to the entire simulation canvas
	//vec3 tmp = vec3(unprojectedUVs.xy, 1.0);
	//tmp.xyz = mul(tmp.xyz, v_XForm);
	//unprojectedUVs = tmp.xy / tmp.z;
	//
	//tmp = vec3(unprojectedUVsLast.xy, 1.0);
	//tmp.xyz = mul(tmp.xyz, v_XForm);
	//unprojectedUVsLast = tmp.xy / tmp.z;
	
	// Block impulse when cursor moves across perspective horizon
	rippleMask *= step(abs(unprojectedUVs.x - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVs.y - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVsLast.x - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVsLast.y - 0.5), 0.5);
#endif

	//unprojectedUVs = (texSource - unprojectedUVs); // * vec2(v_PointDelta.y, v_PointerUV.w);
	//unprojectedUVsLast = (texSource - unprojectedUVsLast); // * vec2(v_PointDelta.y, v_PointerUVLast.w);

	vec2 lDelta = unprojectedUVs - unprojectedUVsLast;
	vec2 texDelta = texSource - unprojectedUVsLast;
	
	float distLDelta = length(lDelta) + 0.0001;
	//distLDelta = max(0.0001, distLDelta);
	lDelta /= distLDelta; // DIV ZERO
	float distOnLine = dot(lDelta, texDelta);
	//distOnLine = distOnLine * distLDelta;
	
	float rayMask = max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.1));
	
	distOnLine = saturate(distOnLine / distLDelta) * distLDelta;
	vec2 posOnLine = unprojectedUVsLast + lDelta * distOnLine;


	unprojectedUVs = (texSource - posOnLine) * vec2(v_PointDelta.y, v_PointerUV.w);

	float pointerDist = length(unprojectedUVs);
	pointerDist = saturate(1.0 - pointerDist);
	
	//pointerDist *= step(0.05 * distLDelta, distOnLine);
	//pointerDist = 1.0;
	pointerDist *= rayMask * rippleMask;
	
	
	float timeAmt = min(1.0 / 30.0, g_Frametime) / 0.02;
	float pointerMoveAmt = v_PointDelta.x;
	float inputStrength = pointerDist * timeAmt * (pointerMoveAmt + g_PointerState.z * 5.0);
	//albedo.a = inputStrength
	//vec2 impulseDir = saturate(unprojectedUVs * 0.5 + CAST2(0.5));
	vec2 impulseDir = max(CAST2(-1.0), min(CAST2(1.0), unprojectedUVs));
	//albedo.b = 1.0;
	
	vec4 colorAdd = vec4(
		step(0.0, impulseDir.x) * impulseDir.x * inputStrength,
		step(0.0, impulseDir.y) * impulseDir.y * inputStrength,
		step(impulseDir.x, 0.0) * -impulseDir.x * inputStrength,
		step(impulseDir.y, 0.0) * -impulseDir.y * inputStrength
	);

	gl_FragColor = albedo + colorAdd;
	
	//gl_FragColor.r = albedo.r + (inputStrength * 0.1);
	//gl_FragColor.g = albedo.g;
	//gl_FragColor.b = 0;
	//gl_FragColor.a = 1;
	
	//colorAdd = vec4(pointerDebug * 0.5 + 0.5, 0, 0);
	//gl_FragColor = colorAdd;
}
