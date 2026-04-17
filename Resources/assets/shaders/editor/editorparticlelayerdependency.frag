
#include "common_fragment.h"

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"OPACITYMASK","paintdefaultcolor":"0 0 0 1"}

varying vec2 v_TexCoord;

void main() {
	gl_FragColor = texSample2D(g_Texture0, v_TexCoord) *
		texSample2D(g_Texture1, v_TexCoord);
}
