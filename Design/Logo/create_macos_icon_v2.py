#!/usr/bin/env python3
"""
WallHaven App Icon - Enhanced Glass Effect
Following macOS Big Sur+ Design Language
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)  # macOS standard

def create_background(size):
    """Create gradient background with subtle texture"""
    # Start with base color
    img = Image.new('RGBA', (size, size), (25, 28, 35, 255))
    draw = ImageDraw.Draw(img)
    
    # Vertical gradient from top to bottom
    top_color = (45, 50, 60)      # Lighter at top
    bottom_color = (15, 17, 20)   # Darker at bottom
    
    for y in range(size):
        ratio = y / size
        r = int(top_color[0] * (1 - ratio) + bottom_color[0] * ratio)
        g = int(top_color[1] * (1 - ratio) + bottom_color[1] * ratio)
        b = int(top_color[2] * (1 - ratio) + bottom_color[2] * ratio)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))
    
    return img


def create_rounded_mask(size, radius):
    """Create rounded rectangle mask"""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=255)
    return mask


def add_glass_highlights(img, size, radius):
    """Add macOS-style glass highlights and reflections"""
    
    # 1. Top edge specular highlight
    highlight_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(highlight_layer)
    
    # Bright top edge line
    for i in range(4):
        alpha = 100 - i * 22
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i],
            radius=radius-i,
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    # 2. Top gradient reflection (glass shine)
    reflection_height = int(size * 0.45)
    for y in range(reflection_height):
        # Strong highlight at very top, fading down
        if y < size * 0.08:
            alpha = int(40 * (1 - y / (size * 0.08)))
        else:
            alpha = int(15 * (1 - (y - size * 0.08) / (reflection_height - size * 0.08)))
        draw.line([(0, y), (size, y)], fill=(255, 255, 255, alpha))
    
    # 3. Bottom inner shadow for depth
    shadow_height = int(size * 0.12)
    for y in range(size - shadow_height, size):
        progress = (y - (size - shadow_height)) / shadow_height
        alpha = int(60 * progress)
        draw.line([(0, y), (size, y)], fill=(0, 0, 0, alpha))
    
    # 4. Side shadows for 3D effect
    side_shadow_width = int(size * 0.03)
    for x in range(side_shadow_width):
        alpha = int(30 * (1 - x / side_shadow_width))
        draw.line([(x, 0), (x, size)], fill=(0, 0, 0, alpha))
        draw.line([(size-1-x, 0), (size-1-x, size)], fill=(0, 0, 0, alpha))
    
    return Image.alpha_composite(img, highlight_layer)


def create_letters(size):
    """Create W and M letters with glass effect"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    
    # Load font
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
                font = ImageFont.truetype(path, int(size * 0.40))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_y = size // 2 + int(size * 0.01)
    w_x = size // 2 - int(size * 0.055)
    m_x = size // 2 + int(size * 0.055)
    
    # Drop shadow
    shadow_offset = int(size * 0.015)
    shadow_color = (0, 0, 0, 100)
    draw.text((w_x + shadow_offset, center_y + shadow_offset), "W", 
              font=font, fill=shadow_color, anchor="mm")
    draw.text((m_x + shadow_offset, center_y + shadow_offset), "M", 
              font=font, fill=shadow_color, anchor="mm")
    
    # Letter colors with slight transparency for glass effect
    w_color = (130, 190, 255, 255)  # Bright blue
    m_color = (255, 150, 200, 240)  # Pink with transparency
    
    # Draw letters
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Letter highlights (top-left shine on letters)
    highlight_offset = -int(size * 0.005)
    highlight_color_w = (200, 230, 255, 80)
    highlight_color_m = (255, 220, 240, 60)
    
    draw.text((w_x + highlight_offset, center_y + highlight_offset), "W", 
              font=font, fill=highlight_color_w, anchor="mm")
    draw.text((m_x + highlight_offset, center_y + highlight_offset), "M", 
              font=font, fill=highlight_color_m, anchor="mm")
    
    return layer


def create_icon(size=1024):
    """Create complete macOS app icon"""
    
    # 1. Background with gradient
    bg = create_background(size)
    
    # 2. Apply rounded corners
    mask = create_rounded_mask(size, CORNER_RADIUS)
    bg.putalpha(mask)
    
    # 3. Add letters
    letters = create_letters(size)
    icon = Image.alpha_composite(bg, letters)
    
    # 4. Add glass highlights and reflections
    icon = add_glass_highlights(icon, size, CORNER_RADIUS)
    
    return icon


def generate_all():
    """Generate all icon sizes"""
    sizes = [
        (16, "icon_16x16"),
        (32, "icon_16x16@2x"),
        (32, "icon_32x32"),
        (64, "icon_32x32@2x"),
        (128, "icon_128x128"),
        (256, "icon_128x128@2x"),
        (256, "icon_256x256"),
        (512, "icon_256x256@2x"),
        (512, "icon_512x512"),
        (1024, "icon_512x512@2x"),
    ]
    
    print("Generating macOS App Icon with enhanced glass effect...")
    
    master = create_icon(1024)
    output_dir = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"
    
    for pixel_size, filename in sizes:
        icon = master.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
        icon.save(f'{output_dir}/{filename}.png')
        print(f"  ✓ {filename}.png")
    
    # Also save to Design folder for reference
    master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Final.png')
    
    print("\n✅ Icon generation complete!")


if __name__ == "__main__":
    generate_all()
