
uniform float g_Time;

varying vec2 v_TexCoord;

varying vec4 v_ViewRect;


void main() {
	vec4 color = vec4(0, 0, 0, 0);
	
	float s = sin((v_TexCoord.y - v_TexCoord.x) * 0.035 /*+ g_Time*/);
	vec4 grid = vec4(1, 1, 0, 0.2) * smoothstep(0.7, 0.8, abs(s));
	
	float f = (step(v_TexCoord.x, v_ViewRect.x) + step(v_ViewRect.z, v_TexCoord.x)) +
		(step(v_TexCoord.y, v_ViewRect.y) + step(v_ViewRect.w, v_TexCoord.y));
	
	color = mix(color, grid, saturate(f));
	
	float borderWidth = 10.0f;
	
	float rightBorder = step(v_ViewRect.x - borderWidth, v_TexCoord.x) * step(v_TexCoord.x, v_ViewRect.x) +
		step(v_ViewRect.z, v_TexCoord.x) * step(v_TexCoord.x, v_ViewRect.z + borderWidth);
	float rightBorderMask = step(v_TexCoord.y, v_ViewRect.w + borderWidth) * step(v_ViewRect.y - borderWidth, v_TexCoord.y);
	
	float leftBorder = step(v_ViewRect.y - borderWidth, v_TexCoord.y) * step(v_TexCoord.y, v_ViewRect.y) +
		step(v_ViewRect.w, v_TexCoord.y) * step(v_TexCoord.y, v_ViewRect.w + borderWidth);
	float leftBorderMask = step(v_TexCoord.x, v_ViewRect.z + borderWidth) * step(v_ViewRect.x - borderWidth, v_TexCoord.x);
	
	float border = rightBorder * rightBorderMask + leftBorder * leftBorderMask;
	
	color = mix(color, vec4(1, 1, 0, 0.5), saturate(border));
	
	gl_FragColor = color;
}
