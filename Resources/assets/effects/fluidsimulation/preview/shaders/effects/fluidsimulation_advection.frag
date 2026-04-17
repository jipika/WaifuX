
// [COMBO] {"material":"ui_editor_properties_point_emitter_count","combo":"POINTEMITTER","type":"options","default":1,"options":[0,1,2,3]}
// [COMBO] {"material":"ui_editor_properties_line_emitter_count","combo":"LINEEMITTER","type":"options","default":0,"options":[0,1,2,3]}
// [COMBO] {"material":"ui_editor_properties_rendering","combo":"RENDERING","type":"options","default":0,"options":{"ui_editor_properties_gradient":0,"ui_editor_properties_emitter_color":1,"ui_editor_properties_background_color":2,"ui_editor_properties_distortion":3}}

uniform float g_Frametime;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
uniform sampler2D g_Texture2; // {"hidden":true}
uniform sampler2D g_Texture3; // {"label":"ui_editor_properties_collision_mask","mode":"opacitymask","combo":"COLLISIONMASK","paintdefaultcolor":"0 0 0 1","painttexturescale":1,"require":{"DYE":0}}
uniform sampler2D g_Texture4; // {"label":"ui_editor_properties_dye_emitter","mode":"rgbmask","combo":"DYEEMITTER","paintdefaultcolor":"0 0 0 1","painttexturescale":1,"require":{"DYE":1}}

uniform vec4 g_Texture0Resolution;

uniform float u_Dissipation; // {"material":"dissipationfactor","label":"ui_editor_properties_dissipation","default":1.0,"range":[0.01, 10.0],"group":"ui_editor_properties_simulation"}
uniform float u_Viscosity; // {"material":"viscosityfactor","label":"ui_editor_properties_viscosity","default":1.0,"range":[0.0, 20.0],"group":"ui_editor_properties_simulation"}
uniform float m_Dissipation; // {"hidden":true,"material":"dissipation","label":"ui_editor_properties_dissipation","default":1.0,"range":[0.0, 1.0],"group":"ui_editor_properties_simulation"}
uniform float u_Lifetime; // {"material":"lifetime","label":"ui_editor_properties_high_pass","default":0.1,"range":[0.1, 1.0],"group":"ui_editor_properties_simulation"}
uniform float u_Saturation; // {"material":"saturation","label":"ui_editor_properties_saturation","default":1.0,"range":[0.0, 1.0]}

varying vec2 v_TexCoord;

uniform float u_ConstantVelocityAngle; // {"material":"forcedirection","label":"ui_editor_properties_direction","default":3.141593,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_gravity"}
uniform float u_ConstantVelocityStrength; // {"material":"forcestrength","label":"ui_editor_properties_strength","default":0.0,"range":[0,100.0],"group":"ui_editor_properties_gravity"}

#if DYE
uniform vec2 m_EmitterPos0; // {"material":"emitterPos0","default":"0.5 0.5"}
uniform float m_EmitterSize0; // {"material":"emitterSize0","default":0.05,"range":[0.0, 0.3]}
uniform vec3 m_EmitterColor0; // {"material":"emitterColor0","label":"ui_editor_properties_color","default":"1 0 0","group":"ui_editor_properties_point_emitter_1","type":"color"}

uniform vec2 m_EmitterPos1; // {"material":"emitterPos1","default":"0.5 0.7"}
uniform float m_EmitterSize1; // {"material":"emitterSize1","default":0.05,"range":[0.0, 0.3]}
uniform vec3 m_EmitterColor1; // {"material":"emitterColor1","label":"ui_editor_properties_color","default":"0 1 0","group":"ui_editor_properties_point_emitter_2","type":"color"}

uniform vec2 m_EmitterPos2; // {"material":"emitterPos2","default":"0.7 0.7"}
uniform float m_EmitterSize2; // {"material":"emitterSize2","default":0.05,"range":[0.0, 0.3]}
uniform vec3 m_EmitterColor2; // {"material":"emitterColor2","label":"ui_editor_properties_color","default":"0 0 1","group":"ui_editor_properties_point_emitter_3","type":"color"}

uniform vec2 m_EmitterPos3; // {"material":"emitterPos3","default":"0.7 0.5"}
uniform float m_EmitterSize3; // {"material":"emitterSize3","default":0.05,"range":[0.0, 0.3]}
uniform vec3 m_EmitterColor3; // {"material":"emitterColor3","label":"ui_editor_properties_color","default":"1 1 0","group":"ui_editor_properties_point_emitter_4","type":"color"}

uniform vec2 m_LineEmitterPosA0; // {"material":"lineEmitterPosA0","default":"0.1 0.1"}
uniform vec2 m_LineEmitterPosB0; // {"material":"lineEmitterPosB0","default":"0.4 0.1"}
uniform float m_LineEmitterSize0; // {"material":"lineEmitterSize0","default":0.02}
uniform vec3 m_LineEmitterColor0; // {"material":"lineEmitterColor0","label":"ui_editor_properties_color","default":"0 1 1","group":"ui_editor_properties_line_emitter_1","type":"color"}

uniform vec2 m_LineEmitterPosA1; // {"material":"lineEmitterPosA1","default":"0.1 0.2"}
uniform vec2 m_LineEmitterPosB1; // {"material":"lineEmitterPosB1","default":"0.4 0.2"}
uniform float m_LineEmitterSize1; // {"material":"lineEmitterSize1","default":0.02}
uniform vec3 m_LineEmitterColor1; // {"material":"lineEmitterColor1","label":"ui_editor_properties_color","default":"1 1 0","group":"ui_editor_properties_line_emitter_2","type":"color"}

uniform vec2 m_LineEmitterPosA2; // {"material":"lineEmitterPosA2","default":"0.1 0.3"}
uniform vec2 m_LineEmitterPosB2; // {"material":"lineEmitterPosB2","default":"0.4 0.3"}
uniform float m_LineEmitterSize2; // {"material":"lineEmitterSize2","default":0.02}
uniform vec3 m_LineEmitterColor2; // {"material":"lineEmitterColor2","label":"ui_editor_properties_color","default":"1 0 1","group":"ui_editor_properties_line_emitter_3","type":"color"}
#endif

#if PERSPECTIVE == 1
varying vec3 v_TexCoordPerspective;
#endif

vec4 AddEmitterColor(vec2 texCoord, float amt, vec4 currentColor, vec3 emitterColor)
{
#if RENDERING == 2
	vec4 prevColor = texSample2D(g_Texture2, texCoord);
	return mix(currentColor, prevColor, amt);
#endif

#if RENDERING == 1
	emitterColor *= amt;
	return min(currentColor + vec4(mix(g_Frametime, 1.0, u_Saturation) * emitterColor, amt), max(CAST4(1.0), vec4(emitterColor, amt)));
	//return mix(currentColor, vec4(emitterColor, 1), amt);
#endif

	// Clamp to max injected color for proper HDR behavior?
	return min(currentColor + CAST4(amt), CAST4(1.0));
}

vec4 EmitterColor(vec2 texCoord, float aspect, vec4 currentColor, vec2 position, float size, vec3 emitterColor)
{
	vec2 delta = position - texCoord;
	delta.y *= aspect;
	float amt = smoothstep(size, 0.0, length(delta));
	
	return AddEmitterColor(texCoord, amt, currentColor, emitterColor);
}

vec4 LineEmitterColor(vec2 texCoord, vec2 linePosA, vec2 linePosB, float aspect, vec4 currentColor, float size, vec3 emitterColor)
{
	vec2 lineDelta = linePosB - linePosA;
	float distLineDelta = length(lineDelta) + 0.0001;
	lineDelta /= distLineDelta;
	float distOnEmitterLine = dot(lineDelta, texCoord - linePosA);
	distOnEmitterLine = max(0.0, min(distLineDelta, distOnEmitterLine));
	vec2 posOnEmitterLine = linePosA + lineDelta * distOnEmitterLine;
	vec2 delta = texCoord - posOnEmitterLine;
	delta.y *= aspect;
	float amt = smoothstep(size, 0.0, length(delta));
	
	return AddEmitterColor(texCoord, amt, currentColor, emitterColor);
}

void main() {
	vec2 vUv = v_TexCoord;
	
	vec2 texelSize = CAST2(1.0) / g_Texture0Resolution.xy;
	float dt = min(1.0/20.0, g_Frametime);
	
	vec2 coord = vUv - dt * texSample2D(g_Texture0, vUv).xy * texelSize;
	vec4 result = texSample2D(g_Texture1, coord);

#if DYE
	float decayFactor = u_Dissipation;
	float boundaryMask = step(0.0, coord.x) *
		step(coord.x, 1.0) *
		step(0.0, coord.y) *
		step(coord.y, 1.0);
#else
	float decayFactor = u_Viscosity;
#endif

	float decay = 1.0 + decayFactor * m_Dissipation * dt;
	//float lowPass = smoothstep(1.0, 0.00001, length(result.rgb)) * 0.5;
	float lowPass = step(length(result.rgb), u_Lifetime) * 0.5;
	
#if DYE
	result *= boundaryMask;
#endif

	gl_FragColor = result / (decay + lowPass);
	float aspect = g_Texture0Resolution.y / g_Texture0Resolution.x;
	
#if DYE
	vec2 emitterUV = v_TexCoord;
	
#if PERSPECTIVE == 1
	emitterUV = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
#endif

	// Add color
#if POINTEMITTER >= 1
	gl_FragColor = EmitterColor(emitterUV, aspect, gl_FragColor, m_EmitterPos0, m_EmitterSize0, m_EmitterColor0);
#endif
#if POINTEMITTER >= 2
	gl_FragColor = EmitterColor(emitterUV, aspect, gl_FragColor, m_EmitterPos1, m_EmitterSize1, m_EmitterColor1);
#endif
#if POINTEMITTER >= 3
	gl_FragColor = EmitterColor(emitterUV, aspect, gl_FragColor, m_EmitterPos2, m_EmitterSize2, m_EmitterColor2);
#endif
#if POINTEMITTER >= 4
	gl_FragColor = EmitterColor(emitterUV, aspect, gl_FragColor, m_EmitterPos3, m_EmitterSize3, m_EmitterColor3);
#endif

#if LINEEMITTER >= 1
	gl_FragColor = LineEmitterColor(emitterUV, m_LineEmitterPosA0, m_LineEmitterPosB0, aspect, gl_FragColor, m_LineEmitterSize0, m_LineEmitterColor0);
#endif
#if LINEEMITTER >= 2
	gl_FragColor = LineEmitterColor(emitterUV, m_LineEmitterPosA1, m_LineEmitterPosB1, aspect, gl_FragColor, m_LineEmitterSize1, m_LineEmitterColor1);
#endif
#if LINEEMITTER >= 3
	gl_FragColor = LineEmitterColor(emitterUV, m_LineEmitterPosA2, m_LineEmitterPosB2, aspect, gl_FragColor, m_LineEmitterSize2, m_LineEmitterColor2);
#endif

#if DYEEMITTER
	vec4 dyeEmitterSample = texSample2D(g_Texture4, v_TexCoord);
	dyeEmitterSample.rgb *= dyeEmitterSample.a;
	gl_FragColor = min(gl_FragColor + vec4(dyeEmitterSample.rgb * u_Saturation,
		saturate(dot(dyeEmitterSample.rgb, CAST3(g_Frametime)) * dyeEmitterSample.a)),
		CAST4(1.0));
#endif

#else
	vec2 constantSpeed = vec2(sin(u_ConstantVelocityAngle), -cos(u_ConstantVelocityAngle)) * u_ConstantVelocityStrength;
	constantSpeed.y *= aspect;
	gl_FragColor.xy += constantSpeed * g_Frametime;
	
#if COLLISIONMASK
	vec2 emitterUV = v_TexCoord;
	
#if PERSPECTIVE == 1
	emitterUV = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
#endif

	vec4 collisionColor = texSample2D(g_Texture3, emitterUV);
	float solid = collisionColor.r * collisionColor.a;
	gl_FragColor.xy = mix(gl_FragColor.xy, vec2(0, 0), solid);
#endif
#endif
}
