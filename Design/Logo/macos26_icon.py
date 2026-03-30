#!/usr/bin/env python3
"""
Generate macOS 26 (Sequoia) compatible app icons
Following Apple's Liquid Glass design guidelines
"""

from PIL import Image, ImageDraw, ImageFont
import math

# macOS 26 App Icon specifications
MASTER_SIZE = 1024
# macOS 26 uses 22% corner radius for the rounded square
CORNER_RADIUS = int(MASTER_SIZE * 0.22)

# Colors for Wallpaper (W) and Motion (M)
W_BLUE = (90, 170, 255)      # Bright blue for Wallpaper
M_PINK = (255, 110, 170)     # Bright pink for Motion
BG_TOP = (45, 50, 65)        # Rich blue-gray top
BG_BOTTOM = (12, 14, 18)     # Deep dark bottom


def create_rounded_mask(size, radius):
    """Create a proper rounded rectangle mask"""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=255)
    return mask


def create_background(size):
    """Create gradient background"""
    img = Image.new('RGB', (size, size), BG_BOTTOM)
    draw = ImageDraw.Draw(img)
    
    # Smooth gradient from top to bottom
    for y in range(size):
        t = y / size
        r = int(BG_TOP[0] * (1-t) + BG_BOTTOM[0] * t)
        g = int(BG_TOP[1] * (1-t) + BG_BOTTOM[1] * t)
        b = int(BG_TOP[2] * (1-t) + BG_BOTTOM[2] * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b))
    
    return img


def create_letters(size):
    """Create W and M letters with macOS 26 style"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    
    # Try to load San Francisco font (macOS system font)
    font = None
    font_paths = [
        "/System/Library/Fonts/SF-Pro-Display-Heavy.otf",
        "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ]
    
    for path in font_paths:
        try:
            font = ImageFont.truetype(path, int(size * 0.42))
            break
        except:
            continue
    
    if font is None:
        font = ImageFont.load_default()
    
    center_y = size // 2 + int(size * 0.01)
    w_x = size // 2 - int(size * 0.055)
    m_x = size // 2 + int(size * 0.055)
    
    # Draw shadow
    shadow_offset = int(size * 0.012)
    shadow_color = (0, 0, 0, 100)
    draw.text((w_x + shadow_offset, center_y + shadow_offset), "W",
              font=font, fill=shadow_color, anchor="mm")
    draw.text((m_x + shadow_offset, center_y + shadow_offset), "M",
              font=font, fill=shadow_color, anchor="mm")
    
    # Draw main letters with solid vibrant colors
    w_fill = (*W_BLUE, 255)
    m_fill = (*M_PINK, 255)
    
    draw.text((w_x, center_y), "W", font=font, fill=w_fill, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=m_fill, anchor="mm")
    
    # Add top highlight for glass effect
    highlight_offset = -int(size * 0.004)
    draw.text((w_x + highlight_offset, center_y + highlight_offset), "W",
              font=font, fill=(255, 255, 255, 90), anchor="mm")
    draw.text((m_x + highlight_offset, center_y + highlight_offset), "M",
              font=font, fill=(255, 255, 255, 70), anchor="mm")
    
    return layer


def add_glass_highlights(img, size, radius):
    """Add macOS Liquid Glass style highlights"""
    glass = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glass)
    
    # Top edge specular highlight (brighter for macOS 26)
    for i in range(3):
        alpha = 150 - i * 40
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i],
            radius=radius-i,
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    # Top reflection gradient
    reflect_height = int(size * 0.4)
    for y in range(reflect_height):
        if y < size * 0.08:
            alpha = int(60 * (1 - y/(size*0.08)))
        else:
            alpha = int(25 * (1 - (y-size*0.08)/(reflect_height-size*0.08)))
        draw.line([(0, y), (size, y)], fill=(255, 255, 255, alpha))
    
    # Bottom shadow for depth
    shadow_height = int(size * 0.12)
    for y in range(size - shadow_height, size):
        progress = (y - (size - shadow_height)) / shadow_height
        draw.line([(0, y), (size, y)], fill=(0, 0, 0, int(60 * progress)))
    
    return Image.alpha_composite(img, glass)


def generate_icon():
    """Generate the complete icon"""
    # Create background
    bg = create_background(MASTER_SIZE)
    
    # Convert to RGBA for compositing
    bg = bg.convert('RGBA')
    
    # Apply rounded corners mask
    mask = create_rounded_mask(MASTER_SIZE, CORNER_RADIUS)
    bg.putalpha(mask)
    
    # Add letters
    letters = create_letters(MASTER_SIZE)
    icon = Image.alpha_composite(bg, letters)
    
    # Add glass highlights
    icon = add_glass_highlights(icon, MASTER_SIZE, CORNER_RADIUS)
    
    return icon


def generate_all_sizes():
    """Generate all required icon sizes for macOS"""
    master = generate_icon()
    
    # macOS app icon sizes
    sizes = {
        "icon_16x16": 16,
        "icon_16x16@2x": 32,
        "icon_32x32": 32,
        "icon_32x32@2x": 64,
        "icon_128x128": 128,
        "icon_128x128@2x": 256,
        "icon_256x256": 256,
        "icon_256x256@2x": 512,
        "icon_512x512": 512,
        "icon_512x512@2x": 1024,
    }
    
    output_dir = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"
    
    print("Generating macOS 26 compatible icons...")
    
    for filename, size in sizes.items():
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(f"{output_dir}/{filename}.png", "PNG")
        print(f"  ✓ {filename}.png ({size}x{size})")
    
    # Also save master copy
    master.save("/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_macOS26.png", "PNG")
    print("\n✅ All icons generated successfully!")


if __name__ == "__main__":
    generate_all_sizes()
