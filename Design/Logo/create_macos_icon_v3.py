#!/usr/bin/env python3
"""
WallHaven App Icon - Final Version
Vibrant colors with macOS glass effect
"""

from PIL import Image, ImageDraw, ImageFont, ImageEnhance

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)

def create_background(size):
    """Create rich gradient background"""
    img = Image.new('RGBA', (size, size), (20, 22, 28, 255))
    draw = ImageDraw.Draw(img)
    
    # Rich gradient from top to bottom
    top_color = (50, 55, 70)      # Rich blue-gray top
    bottom_color = (12, 14, 18)   # Deep dark bottom
    
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


def add_glass_effect(img, size, radius):
    """Add macOS-style glass highlights"""
    glass = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glass)
    
    # 1. Strong top edge specular highlight
    for i in range(3):
        alpha = 120 - i * 35
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i],
            radius=radius-i,
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    # 2. Top reflection gradient (glass shine)
    reflect_h = int(size * 0.5)
    for y in range(reflect_h):
        if y < size * 0.1:
            alpha = int(50 * (1 - y / (size * 0.1)))
        else:
            alpha = int(20 * (1 - (y - size * 0.1) / (reflect_h - size * 0.1)))
        draw.line([(0, y), (size, y)], fill=(255, 255, 255, alpha))
    
    # 3. Bottom shadow for depth
    shadow_h = int(size * 0.15)
    for y in range(size - shadow_h, size):
        progress = (y - (size - shadow_h)) / shadow_h
        alpha = int(70 * progress)
        draw.line([(0, y), (size, y)], fill=(0, 0, 0, alpha))
    
    # 4. Inner shadow on sides
    side = int(size * 0.04)
    for x in range(side):
        alpha = int(35 * (1 - x / side))
        draw.line([(x, 0), (x, size)], fill=(0, 0, 0, alpha))
        draw.line([(size-1-x, 0), (size-1-x, size)], fill=(0, 0, 0, alpha))
    
    return Image.alpha_composite(img, glass)


def create_letters(size):
    """Create vibrant W and M letters"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    
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
    so = int(size * 0.012)
    sc = (0, 0, 0, 90)
    draw.text((w_x + so, center_y + so), "W", font=font, fill=sc, anchor="mm")
    draw.text((m_x + so, center_y + so), "M", font=font, fill=sc, anchor="mm")
    
    # Vibrant colors
    w_color = (100, 180, 255, 255)   # Bright cyan-blue
    m_color = (255, 120, 170, 245)   # Bright pink
    
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Top highlight on letters for glass effect
    ho = -int(size * 0.004)
    hw = (255, 255, 255, 100)
    hm = (255, 255, 255, 80)
    draw.text((w_x + ho, center_y + ho), "W", font=font, fill=hw, anchor="mm")
    draw.text((m_x + ho, center_y + ho), "M", font=font, fill=hm, anchor="mm")
    
    return layer


def create_icon(size=1024):
    """Create complete icon"""
    bg = create_background(size)
    mask = create_rounded_mask(size, CORNER_RADIUS)
    bg.putalpha(mask)
    
    letters = create_letters(size)
    icon = Image.alpha_composite(bg, letters)
    icon = add_glass_effect(icon, size, CORNER_RADIUS)
    
    return icon


def generate():
    sizes = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    
    print("Generating final icon...")
    master = create_icon(1024)
    out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"
    
    for ps, fn in sizes:
        master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
        print(f"  ✓ {fn}")
    
    master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Final.png')
    print("\n✅ Done!")


if __name__ == "__main__":
    generate()
