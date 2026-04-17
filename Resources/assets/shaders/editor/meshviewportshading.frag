
uniform mediump float g_Alpha;

varying vec4 v_ScreenPos;
varying vec4 v_ScreenNorm;

void main() {
	gl_FragColor = vec4(0, 0, 0, g_Alpha);

	vec3 screenPos = v_ScreenPos.xyz / v_ScreenPos.w;
	vec3 screenNorm = normalize(v_ScreenNorm.xyz);

	float light = dot(screenNorm, normalize(vec3(0.707, 0.707, 0.707)));

	float lightPowd = light;
	lightPowd = pow(abs(lightPowd), 2.0) * sign(lightPowd);

	light = light * 0.5 + 0.5;
	lightPowd = lightPowd * 0.5 + 0.5;

	vec3 shadow = vec3(1, 1, 1);
	vec3 mid = vec3(1, 0.2, 0);
	vec3 high = vec3(0, 0, 1.5);

	vec3 res = mix(mix(shadow, mid, smoothstep(0, 0.5, lightPowd)), high, smoothstep(0.5, 1.0, lightPowd));
	
	//gl_FragColor.rgb = screenNorm.rgb * 0.5 + 0.5;
	//gl_FragColor.rgb = pow(gl_FragColor.rgb, 2.0);
	//gl_FragColor.b = -screenNorm.b;
	//gl_FragColor.a *= 0.9;

	//light = light * 0.5 + 0.5;
	res = vec3(1, 1, 1);
	gl_FragColor.rgb = res * pow(light, 0.7);
}