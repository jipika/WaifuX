#!/usr/bin/env python3
"""
Final macOS App Icon - Correct Implementation
Based on Apple Human Interface Guidelines:
- 1024×1024 master size
- 22% corner radius (225px for 1024px)
- Top gradient background
- Glass highlight effect
"""

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
# macOS icons use 22% corner radius
CORNER_RADIUS = int(SIZE * 0.22)

def create_icon():
    # 1. Create background with gradient
    bg = Image.new('RGB', (SIZE, SIZE), (20, 22, 28))
    draw = ImageDraw.Draw(bg)
    
    # Rich gradient background
    for y in range(SIZE):
        t = y / SIZE
        # Top is lighter blue-gray, bottom is darker
        r = int(48 * (1-t) + 18 * t)
        g = int(52 * (1-t) + 20 * t)
        b = int(68 * (1-t) + 26 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))
    
    # 2. Convert to RGBA and apply rounded corners
    bg = bg.convert('RGBA')
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=CORNER_RADIUS, fill=255)
    bg.putalpha(mask)
    
    # 3. Create letters layer
    letters = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    l_draw = ImageDraw.Draw(letters)
    
    # Load system font
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SF-Pro-Display-Heavy.otf", int(SIZE * 0.44))
    except:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(SIZE * 0.44))
        except:
            font = ImageFont.load_default()
    
    cy = SIZE // 2 + int(SIZE * 0.02)
    wx = SIZE // 2 - int(SIZE * 0.06)
    mx = SIZE // 2 + int(SIZE * 0.06)
    
    # Shadow
    so = int(SIZE * 0.014)
    l_draw.text((wx + so, cy + so), "W", font=font, fill=(0, 0, 0, 90), anchor="mm")
    l_draw.text((mx + so, cy + so), "M", font=font, fill=(0, 0, 0, 90), anchor="mm")
    
    # Main letters - solid vibrant colors
    l_draw.text((wx, cy), "W", font=font, fill=(85, 165, 255, 255), anchor="mm")
    l_draw.text((mx, cy), "M", font=font, fill=(255, 100, 160, 255), anchor="mm")
    
    # 4. Composite
    img = Image.alpha_composite(bg, letters)
    
    # 5. Add glass highlights
    glass = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    g_draw = ImageDraw.Draw(glass)
    
    # Top edge highlight (macOS specular highlight)
    for i in range(3):
        a = 130 - i * 35
        g_draw.rounded_rectangle([i, i, SIZE-1-i, SIZE-1-i], radius=CORNER_RADIUS-i, 
                                outline=(255, 255, 255, a), width=1)
    
    # Top reflection gradient (glass effect)
    rh = int(SIZE * 0.4)
    for y in range(rh):
        if y < SIZE * 0.06:
            a = int(50 * (1 - y/(SIZE*0.06)))
        else:
            a = int(20 * (1 - (y-SIZE*0.06)/(rh-SIZE*0.06)))
        g_draw.line([(0, y), (SIZE, y)], fill=(255, 255, 255, a))
    
    # Bottom shadow for depth
    sh = int(SIZE * 0.1)
    for y in range(SIZE - sh, SIZE):
        p = (y - (SIZE - sh)) / sh
        g_draw.line([(0, y), (SIZE, y)], fill=(0, 0, 0, int(55 * p)))
    
    return Image.alpha_composite(img, glass)

# Generate all required sizes
sizes = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

print("Generating macOS app icons...")
master = create_icon()
out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"

for fn, ps in sizes:
    master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
    print(f"  ✓ {fn} ({ps}x{ps})")

master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Final_1024.png')
print("\n✅ Done! Icons saved to project.")
