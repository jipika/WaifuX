#!/usr/bin/env python3
"""
WallHaven App Logo Generator
macOS Big Sur+ style icon with W and M overlapping letters
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

# macOS icon specs
SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)  # macOS standard corner radius

# Colors
BG_COLOR = "#0A0A0A"  # Deep black
ACCENT_COLOR = "#5A7CFF"  # Soft blue-purple accent
TEXT_COLOR = "#FFFFFF"

# Shadow and depth
SHADOW_COLOR = "#000000"
HIGHLIGHT_COLOR = "#FFFFFF"


def create_rounded_rect(size, radius, fill):
    """Create a rounded rectangle image"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=fill)
    return img


def add_gradient_background(img, color1, color2):
    """Add subtle gradient to background"""
    width, height = img.size
    gradient = Image.new('RGBA', (width, height), color1)
    draw = ImageDraw.Draw(gradient)
    
    for y in range(height):
        ratio = y / height
        r = int(color1[0] * (1 - ratio) + color2[0] * ratio)
        g = int(color1[1] * (1 - ratio) + color2[1] * ratio)
        b = int(color1[2] * (1 - ratio) + color2[2] * ratio)
        draw.line([(0, y), (width, y)], fill=(r, g, b, 255))
    
    return gradient


def add_inner_shadow(img, radius, shadow_color, offset=(0, 0), blur=20):
    """Add inner shadow effect for depth"""
    width, height = img.size
    
    # Create shadow layer
    shadow = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle([0, 0, width-1, height-1], radius=radius, fill=shadow_color)
    
    # Blur the shadow
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    
    return shadow


def create_w_m_logo(size=1024):
    """Create the W and M overlapping logo"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Background - pure black with subtle gradient
    bg_color = (10, 10, 10, 255)
    bg_color_bottom = (18, 18, 22, 255)
    
    # Create rounded rectangle background
    bg = create_rounded_rect(size, CORNER_RADIUS, bg_color)
    
    # Add subtle gradient
    gradient = add_gradient_background(bg, bg_color, bg_color_bottom)
    
    # Composite gradient onto background
    bg = Image.alpha_composite(bg, gradient)
    
    # Try to load a font, fallback to default if not available
    try:
        # Try system fonts
        font_paths = [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/System/Library/Fonts/SFCompactDisplay-Bold.otf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ]
        
        font_large = None
        for path in font_paths:
            try:
                font_large = ImageFont.truetype(path, int(size * 0.55))
                break
            except:
                continue
        
        if font_large is None:
            font_large = ImageFont.load_default()
    except:
        font_large = ImageFont.load_default()
    
    # Calculate positions for W and M
    center_x = size // 2
    center_y = size // 2
    
    # W positioning (slightly to the left and up)
    w_offset_x = -int(size * 0.08)
    w_offset_y = -int(size * 0.02)
    w_x = center_x + w_offset_x
    w_y = center_y + w_offset_y
    
    # M positioning (slightly to the right and overlapping)
    m_offset_x = int(size * 0.08)
    m_offset_y = int(size * 0.02)
    m_x = center_x + m_offset_x
    m_y = center_y + m_offset_y
    
    # Draw W with glow effect
    glow_radius = 30
    for i in range(glow_radius, 0, -2):
        alpha = int(40 * (1 - i / glow_radius))
        glow_color = (90, 124, 255, alpha)  # Blue glow
        
        draw.text((w_x - i//2, w_y - i//2), "W", font=font_large, fill=glow_color, anchor="mm")
    
    # Draw W main
    w_color = (120, 140, 255, 255)  # Light blue-purple
    draw.text((w_x, w_y), "W", font=font_large, fill=w_color, anchor="mm")
    
    # Draw M with different color (overlapping)
    m_color_primary = (255, 100, 150, 230)  # Soft pink
    
    # M glow
    for i in range(glow_radius, 0, -2):
        alpha = int(30 * (1 - i / glow_radius))
        glow_color = (255, 100, 150, alpha)
        draw.text((m_x - i//2, m_y - i//2), "M", font=font_large, fill=glow_color, anchor="mm")
    
    # Draw M main (slightly transparent for overlap effect)
    draw.text((m_x, m_y), "M", font=font_large, fill=m_color_primary, anchor="mm")
    
    # Composite the letters onto background
    final = Image.alpha_composite(bg, img)
    
    # Add subtle edge highlight for depth
    highlight = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    
    # Top edge highlight
    for i in range(3):
        alpha = 30 - i * 8
        highlight_draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i], 
            radius=CORNER_RADIUS-i, 
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    final = Image.alpha_composite(final, highlight)
    
    return final


def create_alternative_logo(size=1024):
    """Alternative: More minimalist, geometric approach"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Background
    bg_color = (8, 8, 10, 255)
    bg = create_rounded_rect(size, CORNER_RADIUS, bg_color)
    
    # Create W using geometric lines
    center_x = size // 2
    center_y = size // 2
    letter_size = int(size * 0.35)
    stroke_width = int(size * 0.035)
    
    # W points
    w_left = center_x - int(size * 0.15)
    w_top = center_y - letter_size // 2
    w_bottom = center_y + letter_size // 2
    w_mid_x = center_x - int(size * 0.05)
    w_mid_y = center_y + letter_size // 4
    w_right = center_x + int(size * 0.05)
    
    # Draw W lines
    w_color = (100, 130, 255, 255)
    
    # Left stroke
    draw.line([(w_left, w_top), (w_mid_x, w_mid_y)], fill=w_color, width=stroke_width)
    # Right stroke  
    draw.line([(w_mid_x, w_mid_y), (w_right, w_top)], fill=w_color, width=stroke_width)
    # Additional strokes for W shape
    draw.line([(w_left + int(size*0.08), w_top), (center_x, w_bottom - int(size*0.05))], fill=w_color, width=stroke_width)
    draw.line([(center_x, w_bottom - int(size*0.05)), (w_right + int(size*0.08), w_top)], fill=w_color, width=stroke_width)
    
    # M points (offset to right, overlapping)
    m_offset = int(size * 0.12)
    m_left = w_right + int(size * 0.02)
    m_top = w_top
    m_bottom = w_bottom
    m_mid_x = m_left + int(size * 0.1)
    m_mid_y = w_mid_y - int(size * 0.05)
    m_right = m_left + int(size * 0.2)
    
    # Draw M lines
    m_color = (255, 120, 160, 220)
    
    draw.line([(m_left, m_bottom), (m_mid_x, m_mid_y)], fill=m_color, width=stroke_width)
    draw.line([(m_mid_x, m_mid_y), (m_right, m_bottom)], fill=m_color, width=stroke_width)
    draw.line([(m_left + int(size*0.05), m_bottom), (m_mid_x - int(size*0.02), m_top + int(size*0.1))], fill=m_color, width=stroke_width)
    draw.line([(m_mid_x + int(size*0.02), m_top + int(size*0.1)), (m_right - int(size*0.05), m_bottom)], fill=m_color, width=stroke_width)
    
    # Composite
    final = Image.alpha_composite(bg, img)
    
    return final


def create_clean_typographic_logo(size=1024):
    """Clean typographic approach - overlapping W and M"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    
    # Background with subtle gradient
    bg = Image.new('RGBA', (size, size), (12, 12, 14, 255))
    draw = ImageDraw.Draw(bg)
    
    # Add subtle radial gradient
    for r in range(size//2, 0, -4):
        alpha = int(15 * (1 - r / (size//2)))
        color = (30, 35, 50, alpha)
        draw.ellipse([size//2 - r, size//2 - r, size//2 + r, size//2 + r], fill=color)
    
    # Try to get a nice bold font
    try:
        font_paths = [
            "/System/Library/Fonts/SF-Pro-Display-Heavy.otf",
            "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ]
        
        font = None
        for path in font_paths:
            try:
                font = ImageFont.truetype(path, int(size * 0.5))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_x = size // 2
    center_y = size // 2
    
    # Create separate layers for W and M
    w_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    m_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    
    w_draw = ImageDraw.Draw(w_layer)
    m_draw = ImageDraw.Draw(m_layer)
    
    # Colors - cyan/blue for W, magenta/pink for M
    w_color = (100, 180, 255, 255)  # Cyan-blue
    m_color = (255, 120, 180, 200)  # Pink with transparency for overlap
    
    # W position (left, slightly up)
    w_x = center_x - int(size * 0.06)
    w_y = center_y - int(size * 0.03)
    
    # M position (right, slightly down, overlapping)
    m_x = center_x + int(size * 0.06)
    m_y = center_y + int(size * 0.03)
    
    # Draw W with slight shadow
    shadow_offset = 4
    shadow_color = (0, 0, 0, 100)
    w_draw.text((w_x + shadow_offset, w_y + shadow_offset), "W", font=font, fill=shadow_color, anchor="mm")
    w_draw.text((w_x, w_y), "W", font=font, fill=w_color, anchor="mm")
    
    # Draw M with shadow
    m_draw.text((m_x + shadow_offset, m_y + shadow_offset), "M", font=font, fill=shadow_color, anchor="mm")
    m_draw.text((m_x, m_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Composite layers
    final = Image.alpha_composite(bg, w_layer)
    final = Image.alpha_composite(final, m_layer)
    
    # Add rounded corners mask
    mask = create_rounded_rect(size, CORNER_RADIUS, (255, 255, 255, 255))
    final = Image.alpha_composite(Image.new('RGBA', (size, size), (0, 0, 0, 0)), final)
    final.putalpha(mask.split()[3])
    
    return final


if __name__ == "__main__":
    # Generate all variants
    print("Generating WallHaven App Icons...")
    
    # Variant 1: Typography with glow
    logo1 = create_w_m_logo()
    logo1.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Icon_v1.png')
    print("✓ Generated v1 - Typography with glow")
    
    # Variant 2: Geometric lines
    logo2 = create_alternative_logo()
    logo2.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Icon_v2.png')
    print("✓ Generated v2 - Geometric lines")
    
    # Variant 3: Clean typographic
    logo3 = create_clean_typographic_logo()
    logo3.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Icon_v3.png')
    print("✓ Generated v3 - Clean typographic (recommended)")
    
    # Generate smaller sizes for preview
    sizes = [512, 256, 128, 64]
    for s in sizes:
        logo3.resize((s, s), Image.Resampling.LANCZOS).save(
            f'/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Icon_{s}.png'
        )
    
    print("✓ Generated all sizes")
    print("Done!")
