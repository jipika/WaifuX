
// [COMBO] {"material":"ui_editor_properties_point_emitter_count","combo":"POINTEMITTER","type":"options","default":1,"options":[0,1,2,3]}
// [COMBO] {"material":"ui_editor_properties_line_emitter_count","combo":"LINEEMITTER","type":"options","default":0,"options":[0,1,2,3]}

#include "common.h"

uniform float g_Frametime;
uniform float g_Time;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
uniform sampler2D g_Texture2; // {"hidden":true,"default":"util/noise"}

varying vec2 v_TexCoord;
varying vec4 v_TexCoordLeftTop;
varying vec4 v_TexCoordRightBottom;

uniform vec4 g_PointerState;
varying vec4 v_PointerUV;
varying vec4 v_PointerUVLast;
varying vec2 v_PointDelta;

#if PERSPECTIVE == 1
//varying mat3 v_XForm;
varying vec3 v_TexCoordPerspective;
#endif

uniform vec4 g_Texture0Resolution;

uniform float u_Curl; // {"material":"curl","label":"ui_editor_properties_curling","default":30.0,"range":[0.0, 50.0],"group":"ui_editor_properties_simulation"}

uniform vec2 m_EmitterPos0; // {"material":"emitterPos0","label":"ui_editor_properties_position","default":"0.5 0.5","group":"ui_editor_properties_point_emitter_1"}
uniform float m_EmitterAngle0; // {"material":"emitterAngle0","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_point_emitter_1"}
uniform float m_EmitterSize0; // {"material":"emitterSize0","label":"ui_editor_properties_size","default":0.05,"range":[0.0, 0.3],"group":"ui_editor_properties_point_emitter_1"}
uniform float m_EmitterSpeed0; // {"material":"emitterSpeed0","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_point_emitter_1"}

uniform vec2 m_EmitterPos1; // {"material":"emitterPos1","label":"ui_editor_properties_position","default":"0.5 0.7","group":"ui_editor_properties_point_emitter_2"}
uniform float m_EmitterAngle1; // {"material":"emitterAngle1","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_point_emitter_2"}
uniform float m_EmitterSize1; // {"material":"emitterSize1","label":"ui_editor_properties_size","default":0.05,"range":[0.0, 0.3],"group":"ui_editor_properties_point_emitter_2"}
uniform float m_EmitterSpeed1; // {"material":"emitterSpeed1","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_point_emitter_2"}

uniform vec2 m_EmitterPos2; // {"material":"emitterPos2","label":"ui_editor_properties_position","default":"0.7 0.7","group":"ui_editor_properties_point_emitter_3"}
uniform float m_EmitterAngle2; // {"material":"emitterAngle2","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_point_emitter_3"}
uniform float m_EmitterSize2; // {"material":"emitterSize2","label":"ui_editor_properties_size","default":0.05,"range":[0.0, 0.3],"group":"ui_editor_properties_point_emitter_3"}
uniform float m_EmitterSpeed2; // {"material":"emitterSpeed2","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_point_emitter_3"}

uniform vec2 m_EmitterPos3; // {"material":"emitterPos3","label":"ui_editor_properties_position","default":"0.7 0.5","group":"ui_editor_properties_point_emitter_4"}
uniform float m_EmitterAngle3; // {"material":"emitterAngle3","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_point_emitter_4"}
uniform float m_EmitterSize3; // {"material":"emitterSize3","label":"ui_editor_properties_size","default":0.05,"range":[0.0, 0.3],"group":"ui_editor_properties_point_emitter_4"}
uniform float m_EmitterSpeed3; // {"material":"emitterSpeed3","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_point_emitter_4"}

uniform vec2 m_LineEmitterPosA0; // {"material":"lineEmitterPosA0","label":"p0","default":"0.1 0.1","group":"ui_editor_properties_line_emitter_1"}
uniform vec2 m_LineEmitterPosB0; // {"material":"lineEmitterPosB0","label":"p1","default":"0.4 0.1","group":"ui_editor_properties_line_emitter_1"}
uniform float m_LineEmitterAngle0; // {"material":"lineEmitterAngle0","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_line_emitter_1"}
uniform float m_LineEmitterSize0; // {"material":"lineEmitterSize0","label":"ui_editor_properties_size","default":0.02,"range":[0.0, 0.3],"group":"ui_editor_properties_line_emitter_1"}
uniform float m_LineEmitterSpeed0; // {"material":"lineEmitterSpeed0","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_line_emitter_1"}

uniform vec2 m_LineEmitterPosA1; // {"material":"lineEmitterPosA1","label":"p0","default":"0.1 0.2","group":"ui_editor_properties_line_emitter_2"}
uniform vec2 m_LineEmitterPosB1; // {"material":"lineEmitterPosB1","label":"p1","default":"0.4 0.2","group":"ui_editor_properties_line_emitter_2"}
uniform float m_LineEmitterAngle1; // {"material":"lineEmitterAngle1","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_line_emitter_2"}
uniform float m_LineEmitterSize1; // {"material":"lineEmitterSize1","label":"ui_editor_properties_size","default":0.02,"range":[0.0, 0.3],"group":"ui_editor_properties_line_emitter_2"}
uniform float m_LineEmitterSpeed1; // {"material":"lineEmitterSpeed1","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_line_emitter_2"}

uniform vec2 m_LineEmitterPosA2; // {"material":"lineEmitterPosA2","label":"p0","default":"0.1 0.3","group":"ui_editor_properties_line_emitter_3"}
uniform vec2 m_LineEmitterPosB2; // {"material":"lineEmitterPosB2","label":"p1","default":"0.4 0.3","group":"ui_editor_properties_line_emitter_3"}
uniform float m_LineEmitterAngle2; // {"material":"lineEmitterAngle2","label":"ui_editor_properties_angle","default":0.0,"direction":true,"conversion":"rad2deg","group":"ui_editor_properties_line_emitter_3"}
uniform float m_LineEmitterSize2; // {"material":"lineEmitterSize2","label":"ui_editor_properties_size","default":0.02,"range":[0.0, 0.3],"group":"ui_editor_properties_line_emitter_3"}
uniform float m_LineEmitterSpeed2; // {"material":"lineEmitterSpeed2","label":"ui_editor_properties_force","default":100,"range":[0.0, 1000.0],"group":"ui_editor_properties_line_emitter_3"}

vec2 EmitterVelocity(vec2 texCoord, float aspect, vec2 position, float angle, float size, float speed)
{
	vec2 delta = position - texCoord;
	//delta.y *= aspect;
	float amt = step(length(delta), size) * speed;
	vec2 emitterSpeed = vec2(sin(angle), -cos(angle)) * amt;
	//emitterSpeed.y *= aspect;
	return emitterSpeed;
}

vec2 LineEmitterVelocity(vec2 texCoord, vec2 linePosA, vec2 linePosB, float aspect, float angle, float size, float speed, vec2 noise)
{
	vec2 lineDelta = linePosB - linePosA;
	float distLineDelta = length(lineDelta) + 0.0001;
	lineDelta /= distLineDelta;
	float distOnEmitterLine = dot(lineDelta, texCoord - linePosA);
	distOnEmitterLine = max(0.0, min(distLineDelta, distOnEmitterLine));
	vec2 posOnEmitterLine = linePosA + lineDelta * distOnEmitterLine;
	vec2 delta = texCoord - posOnEmitterLine;
	//delta.y *= aspect;
	float amt = step(length(delta), size) * g_Frametime * speed;
	
	vec2 emitterSpeed = vec2(sin(angle), -cos(angle)) * amt;
	//emitterSpeed.y *= aspect;
	emitterSpeed *= step(CAST2(0.5), noise);
	
	return emitterSpeed;
	
}

void main() {
	//vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	//gl_FragColor = albedo;
	
	float dt = min(1.0/20.0, g_Frametime);
	//float dt = 1.0 / 60.0;
	
	vec2 vUv = v_TexCoord;
	vec2 vL = v_TexCoordLeftTop.xy;
	vec2 vR = v_TexCoordRightBottom.xy;
	vec2 vT = v_TexCoordLeftTop.zw;
	vec2 vB = v_TexCoordRightBottom.zw;

	float L = texSample2D(g_Texture1, vL).x;
	float R = texSample2D(g_Texture1, vR).x;
	float T = texSample2D(g_Texture1, vT).x;
	float B = texSample2D(g_Texture1, vB).x;
	float C = texSample2D(g_Texture1, vUv).x;
	vec2 force = 0.5 * vec2(abs(T) - abs(B), abs(R) - abs(L));
	force /= length(force) + 0.0001;
	force *= u_Curl * C;
	force.y *= -1.0;
	vec2 velocity = texSample2D(g_Texture0, v_TexCoord).xy;
	velocity += force * dt;
	velocity = min(max(velocity, -1000.0), 1000.0);
	
	
	vec2 emitterUV = v_TexCoord;
	
#if PERSPECTIVE == 1
	emitterUV = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
#endif

	// Add emitter velocities
	float aspect = g_Texture0Resolution.y / g_Texture0Resolution.x;
	
#if POINTEMITTER >= 1
	velocity += EmitterVelocity(emitterUV, aspect, m_EmitterPos0, m_EmitterAngle0, m_EmitterSize0, g_Frametime * m_EmitterSpeed0);
#endif
#if POINTEMITTER >= 2
	velocity += EmitterVelocity(emitterUV, aspect, m_EmitterPos1, m_EmitterAngle1, m_EmitterSize1, g_Frametime * m_EmitterSpeed1);
#endif
#if POINTEMITTER >= 3
	velocity += EmitterVelocity(emitterUV, aspect, m_EmitterPos2, m_EmitterAngle2, m_EmitterSize2, g_Frametime * m_EmitterSpeed2);
#endif
#if POINTEMITTER >= 4
	velocity += EmitterVelocity(emitterUV, aspect, m_EmitterPos3, m_EmitterAngle3, m_EmitterSize3, g_Frametime * m_EmitterSpeed3);
#endif
	
#if LINEEMITTER >= 1
	vec2 noise = texSample2D(g_Texture2, emitterUV * 0.1 + g_Time * 0.01).rg;
	velocity += LineEmitterVelocity(emitterUV, m_LineEmitterPosA0, m_LineEmitterPosB0, aspect, m_LineEmitterAngle0, m_LineEmitterSize0, m_LineEmitterSpeed0, noise);
#endif
#if LINEEMITTER >= 2
	velocity += LineEmitterVelocity(emitterUV, m_LineEmitterPosA1, m_LineEmitterPosB1, aspect, m_LineEmitterAngle1, m_LineEmitterSize1, m_LineEmitterSpeed1, noise);
#endif
#if LINEEMITTER >= 3
	velocity += LineEmitterVelocity(emitterUV, m_LineEmitterPosA2, m_LineEmitterPosB2, aspect, m_LineEmitterAngle2, m_LineEmitterSize2, m_LineEmitterSpeed2, noise);
#endif

	// Cursor velocity interaction
	vec2 texSource = v_TexCoord.xy;
	vec2 unprojectedUVs = v_PointerUV.xy;
	vec2 unprojectedUVsLast = v_PointerUVLast.xy;
	
	float rippleMask = 1.0;
	
#if PERSPECTIVE == 1
	// Block impulse when cursor moves across perspective horizon
	rippleMask *= step(abs(unprojectedUVs.x - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVs.y - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVsLast.x - 0.5), 0.5);
	rippleMask *= step(abs(unprojectedUVsLast.y - 0.5), 0.5);
#endif

	vec2 lDelta = unprojectedUVs - unprojectedUVsLast;
	vec2 texDelta = texSource - unprojectedUVsLast;
	
	float distLDelta = length(lDelta) + 0.0001;
	lDelta /= distLDelta; // DIV ZERO
	float distOnLine = dot(lDelta, texDelta);
	//distOnLine = distOnLine * distLDelta;
	
	float rayMask = max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.1));
	
	distOnLine = saturate(distOnLine / distLDelta) * distLDelta;
	vec2 posOnLine = unprojectedUVsLast + lDelta * distOnLine;

	unprojectedUVs = (texSource - posOnLine) * vec2(v_PointDelta.y, v_PointerUV.w);

	float pointerDist = length(unprojectedUVs);
	pointerDist = saturate(1.0 - pointerDist);
	
	pointerDist *= rayMask * rippleMask;
	
	float timeAmt = 1.0; //g_Frametime / 0.1;
	float pointerMoveAmt = v_PointDelta.x;
	float inputStrength = pointerDist * timeAmt * (pointerMoveAmt + g_PointerState.z);
	vec2 impulseDir = lDelta;
	
	vec2 colorAdd = vec2(
		impulseDir.x * inputStrength,
		impulseDir.y * inputStrength
	);

	//gl_FragColor.xy += colorAdd * 300;
	velocity += colorAdd * 300;
	
	gl_FragColor = vec4(velocity, 0.0, 1.0);
}
