
#include "common.h"
#include "common_blending.h"

uniform float g_CompositeAlpha; // {"material":"compositealpha","label":"ui_editor_properties_alpha","default":1,"range":[0.0, 2.0]}
uniform vec2 g_CompositeOffset; // {"material":"compositeoffset","label":"ui_editor_properties_offset","default":"0 0","linked":true,"range":[-10.0, 10.0]}
uniform vec3 g_CompositeColor; // {"material":"compositecolor","label":"ui_editor_properties_color","default":"1 1 1","type":"color"}

vec2 ApplyCompositeOffset(vec2 texCoords, vec2 textureResolution)
{
#if COMPOSITE != 0
	return texCoords + g_CompositeOffset / textureResolution;
#else
	return texCoords;
#endif
}

vec4 ApplyComposite(vec4 original, vec4 effect)
{
#if COMPOSITEMONO == 1
	effect.rgb = CAST3(greyscale(effect.rgb));
#endif

	effect.rgb *= g_CompositeColor;

	// Only return the effect
#if COMPOSITE == 0
	return effect;
#endif

	// Overlay the effect with a blend mode
#if COMPOSITE == 1
	effect.rgb = ApplyBlending(BLENDMODE, original.rgb, effect.rgb, effect.a * g_CompositeAlpha);
	effect.a = max(effect.a * saturate(g_CompositeAlpha), original.a);
#endif

	// Put the effect below the original
#if COMPOSITE == 2
	effect.a *= saturate(g_CompositeAlpha);
	effect = mix(effect, original, original.a);
#endif

	// Turn the pixels where the original is invisible
#if COMPOSITE == 3
	effect.a *= saturate(g_CompositeAlpha);
	effect.a *= 1.0 - original.a;
#endif

	return effect;
}
