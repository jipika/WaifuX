#!/usr/bin/env python3
"""
Generate complete macOS App Icon Set
"""

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.225)


def create_logo(size=1024):
    """Create the logo"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Black background
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=int(size * 0.225), fill=(10, 10, 12, 255))
    
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
    w_x = size // 2 - int(size * 0.055)
    m_x = size // 2 + int(size * 0.055)
    shadow_off = int(size * 0.006)
    
    w_color = (100, 170, 255, 255)
    m_color = (255, 130, 180, 215)
    shadow_color = (0, 0, 0, 100)
    
    # Shadows
    draw.text((w_x + shadow_off, center_y + shadow_off), "W", font=font, fill=shadow_color, anchor="mm")
    draw.text((m_x + shadow_off, center_y + shadow_off), "M", font=font, fill=shadow_color, anchor="mm")
    
    # Letters
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Top highlight
    for i in range(2):
        draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i], 
            radius=int(size * 0.225)-i, 
            outline=(255, 255, 255, 35 - i*15),
            width=1
        )
    
    return img


def generate_iconset():
    """Generate all required icon sizes for macOS"""
    
    # macOS App Icon sizes
    sizes = [
        (16, "16x16"),
        (32, "16x16@2x"),
        (32, "32x32"),
        (64, "32x32@2x"),
        (128, "128x128"),
        (256, "128x128@2x"),
        (256, "256x256"),
        (512, "256x256@2x"),
        (512, "512x512"),
        (1024, "512x512@2x"),
    ]
    
    print("Generating macOS App Icon Set...")
    
    # Generate master at 1024
    master = create_logo(1024)
    
    for pixel_size, filename in sizes:
        icon = master.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
        icon.save(f'/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon.appiconset/AppIcon_{filename}.png')
        print(f"  ✓ {filename}.png ({pixel_size}x{pixel_size})")
    
    print("\nDone!")


if __name__ == "__main__":
    generate_iconset()
