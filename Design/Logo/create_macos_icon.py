#!/usr/bin/env python3
"""
WallHaven App Icon - macOS Design Guidelines Compliant
Following Apple Human Interface Guidelines for macOS App Icons
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

# macOS App Icon specs
SIZE = 1024
# macOS 使用方形画布，系统会自动应用圆角遮罩
# 但实际设计时我们需要创建带圆角的图标

# macOS Big Sur+ corner radius is approximately 22.5% of the icon size
CORNER_RADIUS = int(SIZE * 0.225)

# Colors
BG_COLOR_TOP = (35, 38, 45)      # 深蓝灰色顶部
BG_COLOR_BOTTOM = (18, 20, 24)   # 深色底部
ACCENT_BLUE = (100, 170, 255)    # 壁纸蓝
ACCENT_PINK = (255, 130, 180)    # 媒体粉


def create_gradient_background(size, color_top, color_bottom):
    """Create vertical gradient background"""
    img = Image.new('RGBA', (size, size), color_top)
    draw = ImageDraw.Draw(img)
    
    for y in range(size):
        ratio = y / size
        r = int(color_top[0] * (1 - ratio) + color_bottom[0] * ratio)
        g = int(color_top[1] * (1 - ratio) + color_bottom[1] * ratio)
        b = int(color_top[2] * (1 - ratio) + color_bottom[2] * ratio)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))
    
    return img


def create_rounded_mask(size, radius):
    """Create rounded rectangle mask"""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=255)
    return mask


def add_glass_highlight(img, size, radius):
    """Add macOS-style glass highlight effect"""
    # Top edge highlight (specular highlight)
    highlight = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(highlight)
    
    # Main top highlight
    for i in range(3):
        alpha = 60 - i * 18
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i],
            radius=radius-i,
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    # Top gradient highlight (glass reflection)
    reflection_height = int(size * 0.35)
    for y in range(reflection_height):
        alpha = int(25 * (1 - y / reflection_height))
        draw.line([(0, y), (size, y)], fill=(255, 255, 255, alpha))
    
    # Bottom edge shadow for depth
    shadow_height = int(size * 0.08)
    for y in range(size - shadow_height, size):
        alpha = int(40 * ((y - (size - shadow_height)) / shadow_height))
        draw.line([(0, y), (size, y)], fill=(0, 0, 0, alpha))
    
    return Image.alpha_composite(img, highlight)


def add_inner_shadow(img, size, radius):
    """Add subtle inner shadow for depth"""
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    
    # Inner shadow at bottom
    for i in range(4):
        alpha = 30 - i * 6
        offset = i + 2
        draw.rounded_rectangle(
            [offset, offset, size-1-offset, size-1-offset],
            radius=radius-offset,
            outline=(0, 0, 0, alpha),
            width=1
        )
    
    return Image.alpha_composite(img, shadow)


def create_letters_layer(size):
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
                font = ImageFont.truetype(path, int(size * 0.42))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_y = size // 2 + int(size * 0.02)  # Slightly lower for visual balance
    w_x = size // 2 - int(size * 0.06)
    m_x = size // 2 + int(size * 0.06)
    
    # Shadow for depth (offset down-right)
    shadow_offset = int(size * 0.012)
    shadow_color = (0, 0, 0, 120)
    
    # W shadow
    draw.text((w_x + shadow_offset, center_y + shadow_offset), "W", 
              font=font, fill=shadow_color, anchor="mm")
    # M shadow
    draw.text((m_x + shadow_offset, center_y + shadow_offset), "M", 
              font=font, fill=shadow_color, anchor="mm")
    
    # W color - gradient-like blue
    w_color = (120, 185, 255, 255)
    # M color - gradient-like pink with slight transparency for overlap effect
    m_color = (255, 145, 195, 235)
    
    # Draw W
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    
    # Draw M (overlapping with transparency)
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    return layer


def add_letter_highlight(img, size):
    """Add subtle highlight to letters for glass effect"""
    highlight = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(highlight)
    
    # Top-left highlight on letters
    offset = -int(size * 0.008)
    highlight_color = (255, 255, 255, 60)
    
    try:
        font_paths = [
            "/System/Library/Fonts/SF-Pro-Display-Heavy.otf",
            "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
        
        font = None
        for path in font_paths:
            try:
                font = ImageFont.truetype(path, int(size * 0.42))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_y = size // 2 + int(size * 0.02) + offset
    w_x = size // 2 - int(size * 0.06) + offset
    m_x = size // 2 + int(size * 0.06) + offset
    
    draw.text((w_x, center_y), "W", font=font, fill=highlight_color, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=highlight_color, anchor="mm")
    
    return Image.alpha_composite(img, highlight)


def create_macos_icon(size=1024):
    """Create complete macOS app icon with glass effects"""
    
    # 1. Create gradient background
    bg = create_gradient_background(size, BG_COLOR_TOP, BG_COLOR_BOTTOM)
    
    # 2. Apply rounded corners mask
    mask = create_rounded_mask(size, CORNER_RADIUS)
    bg.putalpha(mask)
    
    # 3. Add letters layer
    letters = create_letters_layer(size)
    icon = Image.alpha_composite(bg, letters)
    
    # 4. Add letter highlight for glass effect
    icon = add_letter_highlight(icon, size)
    
    # 5. Add inner shadow for depth
    icon = add_inner_shadow(icon, size, CORNER_RADIUS)
    
    # 6. Add glass highlight (specular + reflection)
    icon = add_glass_highlight(icon, size, CORNER_RADIUS)
    
    return icon


def generate_iconset():
    """Generate all required icon sizes for macOS"""
    
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
    
    print("Generating macOS App Icon Set with glass effects...")
    
    # Generate master at 1024
    master = create_macos_icon(1024)
    
    output_dir = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"
    
    for pixel_size, filename in sizes:
        icon = master.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
        icon.save(f'{output_dir}/{filename}.png')
        print(f"  ✓ {filename}.png ({pixel_size}x{pixel_size})")
    
    print("\n✅ All icons generated with macOS glass effects!")


if __name__ == "__main__":
    generate_iconset()
