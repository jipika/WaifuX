// [COMBO] {"material":"ui_editor_properties_point_filter","combo":"POINTFILTER","type":"options","default":1}
// [COMBO] {"material":"ui_editor_properties_multiply","combo":"MULTIPLY","type":"options","default":1}

uniform vec4 g_Texture0Resolution;
uniform vec2 g_TexelSize;

// The coordinates of the current pixel within the space spanning (0, 0) to (new x, new y).
varying vec2 v_PixelCoord;
// x and y are the width and height of a 'new' pixel in 0 to 1 coordinate space. z and w are the same for an old pixel
varying vec4 v_PixelSize;

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}

#ifdef HLSL
    #define fract frac
#endif

void main() {
#if POINTFILTER
    // Sample the nearest 'old' pixel
    vec2 texCoord00 = round(v_PixelCoord) * v_PixelSize.xy;
    texCoord00 = round(texCoord00 * g_Texture0Resolution.xy) * v_PixelSize.zw + v_PixelSize.zw * 0.5;
    vec4 finalColor = texSample2D(g_Texture0, texCoord00);
#else
    // Bilinear Filtering
    vec2 texCoord00 = floor(v_PixelCoord) * v_PixelSize.xy; // Top-left
    vec2 texCoord01 = texCoord00 + vec2(0.0, v_PixelSize.y); // Bottom-left
    vec2 texCoord10 = texCoord00 + vec2(v_PixelSize.x, 0.0); // Top-right
    vec2 texCoord11 = texCoord00 + vec2(v_PixelSize.x, v_PixelSize.y); // Bottom-right
    vec2 lerp = fract(v_PixelCoord);

    // Sample each corner pixel, weighted by how close this subpixel is to them.
    vec4 finalColor = texSample2D(g_Texture0, texCoord00) * (1.0 - lerp.x) * (1.0 - lerp.y) +
                      texSample2D(g_Texture0, texCoord01) * (1.0 - lerp.x) * lerp.y + 
                      texSample2D(g_Texture0, texCoord10) * lerp.x * (1.0 - lerp.y) + 
                      texSample2D(g_Texture0, texCoord11) * lerp.x * lerp.y;
#endif

    gl_FragColor = finalColor;
}
