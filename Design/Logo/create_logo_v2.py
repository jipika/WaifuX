#!/usr/bin/env python3
"""
WallHaven App Logo Generator v2
Clean macOS Big Sur style icon
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)  # macOS standard


def create_rounded_rect_mask(size, radius):
    """Create a rounded rectangle mask"""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, size-1, size-1], radius=radius, fill=255)
    return mask


def create_premium_logo(size=1024):
    """Premium clean logo with pure black background"""
    # Create base image with pure black background
    img = Image.new('RGBA', (size, size), (10, 10, 12, 255))
    draw = ImageDraw.Draw(img)
    
    # Add subtle inner gradient (very subtle, just for depth)
    for i in range(size // 2, 0, -2):
        alpha = int(8 * (1 - i / (size // 2)))
        color = (25, 28, 35, alpha)
        draw.ellipse([size//2 - i, size//2 - i, size//2 + i, size//2 + i], fill=color)
    
    # Try to load SF Pro or system font
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
                font = ImageFont.truetype(path, int(size * 0.45))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_x = size // 2
    center_y = size // 2
    
    # W and M positioning for overlap effect
    # W slightly left and up
    w_x = center_x - int(size * 0.06)
    w_y = center_y - int(size * 0.02)
    
    # M slightly right and down, overlapping W
    m_x = center_x + int(size * 0.06)
    m_y = center_y + int(size * 0.02)
    
    # Draw shadow layer first
    shadow_offset = int(size * 0.008)
    shadow_color = (0, 0, 0, 80)
    
    # W shadow
    draw.text((w_x + shadow_offset, w_y + shadow_offset), "W", font=font, fill=shadow_color, anchor="mm")
    # M shadow
    draw.text((m_x + shadow_offset, m_y + shadow_offset), "M", font=font, fill=shadow_color, anchor="mm")
    
    # Colors
    w_color = (100, 160, 255, 255)  # Cyan-blue for Wallpaper
    m_color = (255, 130, 180, 210)  # Pink with transparency for Motion
    
    # Draw W (behind)
    draw.text((w_x, w_y), "W", font=font, fill=w_color, anchor="mm")
    
    # Draw M (front, with transparency to show overlap)
    draw.text((m_x, m_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Apply rounded corners mask
    mask = create_rounded_rect_mask(size, CORNER_RADIUS)
    img.putalpha(mask)
    
    # Add subtle edge highlight for depth (top edge)
    highlight = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    
    # Very subtle top highlight
    for i in range(2):
        alpha = 40 - i * 15
        highlight_draw.rounded_rectangle(
            [i, i, size-1-i, size-1-i], 
            radius=CORNER_RADIUS-i, 
            outline=(255, 255, 255, alpha),
            width=1
        )
    
    # Composite highlight
    img = Image.alpha_composite(img, highlight)
    
    return img


def create_minimal_logo(size=1024):
    """Ultra minimal - just black with white/light gray letters"""
    img = Image.new('RGBA', (size, size), (8, 8, 10, 255))
    draw = ImageDraw.Draw(img)
    
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
    
    center_x = size // 2
    center_y = size // 2
    
    # Position for overlap
    w_x = center_x - int(size * 0.05)
    m_x = center_x + int(size * 0.05)
    
    # Pure white for W
    w_color = (255, 255, 255, 255)
    # Slightly transparent white for M  
    m_color = (255, 255, 255, 180)
    
    # Draw W
    draw.text((w_x, center_y), "W", font=font, fill=w_color, anchor="mm")
    
    # Draw M (overlapping)
    draw.text((m_x, center_y), "M", font=font, fill=m_color, anchor="mm")
    
    # Apply rounded corners
    mask = create_rounded_rect_mask(size, CORNER_RADIUS)
    img.putalpha(mask)
    
    return img


def create_gradient_letters_logo(size=1024):
    """Letters with gradient fill"""
    img = Image.new('RGBA', (size, size), (12, 12, 14, 255))
    
    # Create letter mask
    letter_img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    letter_draw = ImageDraw.Draw(letter_img)
    
    try:
        font_paths = [
            "/System/Library/Fonts/SF-Pro-Display-Heavy.otf",
            "/System/Library/Fonts/SF-Pro-Display-Bold.otf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
        
        font = None
        for path in font_paths:
            try:
                font = ImageFont.truetype(path, int(size * 0.48))
                break
            except:
                continue
        
        if font is None:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()
    
    center_x = size // 2
    center_y = size // 2
    
    # Position W
    w_x = center_x - int(size * 0.06)
    # Position M
    m_x = center_x + int(size * 0.06)
    
    # Draw letters to mask
    letter_draw.text((w_x, center_y), "W", font=font, fill=(255, 255, 255, 255), anchor="mm")
    letter_draw.text((m_x, center_y), "M", font=font, fill=(255, 255, 255, 255), anchor="mm")
    
    # Create gradient for W (blue to purple)
    w_gradient = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    w_draw = ImageDraw.Draw(w_gradient)
    for y in range(size):
        ratio = y / size
        r = int(100 + (150 - 100) * ratio)
        g = int(150 + (100 - 150) * ratio)  
        b = int(255 + (200 - 255) * ratio)
        w_draw.line([(0, y), (size, y)], fill=(r, g, b, 255))
    
    # Create gradient for M (pink to orange)
    m_gradient = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    m_draw = ImageDraw.Draw(m_gradient)
    for y in range(size):
        ratio = y / size
        r = int(255)
        g = int(100 + (150 - 100) * ratio)
        b = int(150 + (100 - 150) * ratio)
        m_draw.line([(0, y), (size, y)], fill=(r, g, b, 200))
    
    # Composite
    result = Image.new('RGBA', (size, size), (12, 12, 14, 255))
    
    # Add subtle vignette
    for i in range(size // 2, size // 3, -1):
        alpha = int(20 * (1 - (i - size // 3) / (size // 2 - size // 3)))
        draw_temp = ImageDraw.Draw(result)
        draw_temp.ellipse([center_x - i, center_y - i, center_x + i, center_y + i], 
                         outline=(20, 22, 28, alpha), width=1)
    
    # Paste gradients masked by letters
    result = Image.alpha_composite(result, Image.composite(w_gradient, Image.new('RGBA', (size, size), (0,0,0,0)), 
                                                           letter_img.split()[3]))
    
    # Apply rounded corners
    mask = create_rounded_rect_mask(size, CORNER_RADIUS)
    result.putalpha(mask)
    
    return result


if __name__ == "__main__":
    print("Generating WallHaven App Icons v2...")
    
    # Premium version (recommended)
    logo1 = create_premium_logo()
    logo1.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_AppIcon.png')
    logo1.resize((256, 256), Image.Resampling.LANCZOS).save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_AppIcon_256.png')
    logo1.resize((128, 128), Image.Resampling.LANCZOS).save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_AppIcon_128.png')
    print("✓ Generated Premium Icon")
    
    # Minimal version
    logo2 = create_minimal_logo()
    logo2.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Minimal.png')
    print("✓ Generated Minimal Icon")
    
    # Gradient version
    logo3 = create_gradient_letters_logo()
    logo3.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/WallHaven_Gradient.png')
    print("✓ Generated Gradient Icon")
    
    print("Done! Check /Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/")
