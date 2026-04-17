
// [OFF_COMBO] {"material":"ui_editor_properties_position","combo":"POSITION","type":"options","default":0,"options":{"Center":0,"Post":1,"Pre":2}}

varying vec4 v_TexCoord;
varying vec2 v_Scroll;
varying vec4 v_Cycles;
varying vec2 v_Blend;

uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_flow_map","mode":"flowmask","default":"util/noflow"}
uniform sampler2D g_Texture2; // {"label":"ui_editor_properties_time_offset"}

uniform float g_FlowAmp; // {"material":"strength","label":"ui_editor_properties_strength","default":1,"range":[0.01, 2]}
uniform float g_FlowPhaseScale; // {"material":"phasescale","label":"ui_editor_properties_phase_scale","default":2,"range":[0.01, 10]}

void main() {

	float flowPhase = texSample2D(g_Texture2, v_TexCoord.xy * g_FlowPhaseScale).r;
	vec2 flowColors = texSample2D(g_Texture1, v_TexCoord.zw).rg;
	vec2 flowMask = (flowColors.rg - vec2(0.498, 0.498)) * 2.0;
	float flowAmount = length(flowMask);

	vec4 flowUVOffset = CAST4(flowMask.xyxy * g_FlowAmp * 0.1) * v_Cycles.xxyy;
	vec4 flowUVOffset2 = CAST4(flowMask.xyxy * g_FlowAmp * 0.1) * v_Cycles.zzww;

	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
	vec4 flowAlbedo = mix(texSample2D(g_Texture0, v_TexCoord.xy + flowUVOffset.xy),
					texSample2D(g_Texture0, v_TexCoord.xy + flowUVOffset.zw),
					v_Blend.x);

	vec4 flowAlbedo2 = mix(texSample2D(g_Texture0, v_TexCoord.xy + flowUVOffset2.xy),
					texSample2D(g_Texture0, v_TexCoord.xy + flowUVOffset2.zw),
					v_Blend.y);

	flowAlbedo = mix(flowAlbedo, flowAlbedo2, smoothstep(0.2, 0.8, flowPhase));
	gl_FragColor = mix(albedo, flowAlbedo, flowAmount);
}
