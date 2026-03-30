#!/usr/bin/env python3
"""
WallHaven App Logo - Final Version
Pure macOS Big Sur style
"""

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.225)  # macOS Big Sur corner radius


def create_logo_final(size=1024, style="color"):
    """
    Create final logo
    style: "color" (blue/pink) or "mono" (white/gray)
    """
    # Pure black background - no gradients
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Draw pure black rounded rectangle
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=CORNER_RADIUS, fill=(10, 10, 12, 255))
    
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
                font = ImageFont.truetype(path, int(size * 0.44))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_y = size // 2
    
    # W position (left)
    w_x = size // 2 - int(size * 0.055)
    # M position (right, overlapping)
    m_x = size // 2 + int(size * 0.055)
    
    # Shadow offset
    shadow_off = int(size * 0.006)
    
    if style == "color":
        # Color version - Blue W, Pink M
        w_color = (100, 170, 255, 255)      # Soft blue
        m_color = (255, 130, 180, 215)      # Pink with transparency
        shadow_color = (0, 0, 0, 100)
    else:
        # Monochrome version
        w_color = (255, 255, 255, 255)      # White
        m_color = (255, 255, 255, 160)      # Transparent white
        shadow_color = (0, 0, 0, 80)
    
    # Draw shadows
    draw.text((w_x + shadow_off, center_y + shadow_off), "W", font=font, fill=shadow_color, anchor="mm")
    draw.text((m_x + shadow_off, center_y + shadow_off), "M", font=font, fill=shadow_color, anchor="mm")
    
    # Draw W (back)
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    
    # Draw M (front, overlapping)
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Add subtle top edge highlight for depth (macOS style)
    for i in range(2):
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i], 
            radius=CORNER_RADIUS-i, 
            outline=(255, 255, 255, 35 - i*15),
            width=1
        )
    
    return img


def create_logo_simple(size=1024):
    """Simple flat design, no shadows"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Black background
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=CORNER_RADIUS, fill=(8, 8, 10, 255))
    
    try:
        font_paths = [
            "/System/Library/Fonts/SF-Pro-Display-Heavy.otf",
            "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
        
        font = None
        for path in font_paths:
            try:
                font = ImageFont.truetype(path, int(size * 0.46))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_y = size // 2
    w_x = size // 2 - int(size * 0.05)
    m_x = size // 2 + int(size * 0.05)
    
    # Flat colors, no shadows
    w_color = (120, 180, 255, 255)  # Light blue
    m_color = (255, 140, 190, 200)  # Light pink
    
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    return img


if __name__ == "__main__":
    print("Generating final WallHaven App Icons...")
    
    # Main color version
    logo = create_logo_final(SIZE, "color")
    logo.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon.png')
    logo.resize((512, 512), Image.Resampling.LANCZOS).save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_512.png')
    logo.resize((256, 256), Image.Resampling.LANCZOS).save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_256.png')
    logo.resize((128, 128), Image.Resampling.LANCZOS).save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_128.png')
    print("✓ Main color icon generated")
    
    # Monochrome version (for light/dark mode compatibility)
    logo_mono = create_logo_final(SIZE, "mono")
    logo_mono.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Mono.png')
    print("✓ Monochrome icon generated")
    
    # Simple flat version
    logo_simple = create_logo_simple(SIZE)
    logo_simple.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Flat.png')
    print("✓ Flat icon generated")
    
    print("\nAll icons saved to /Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/")
    print("Recommended: AppIcon.png (1024x1024) for App Store")
