#!/usr/bin/env python3
"""
Enhanced macOS Liquid Glass App Icon
Stronger specular highlights and glass effects
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)

def create_icon():
    # 1. Background with richer gradient
    bg = Image.new('RGB', (SIZE, SIZE), (15, 17, 22))
    draw = ImageDraw.Draw(bg)
    
    for y in range(SIZE):
        t = y / SIZE
        r = int(55 * (1-t) + 15 * t)
        g = int(60 * (1-t) + 17 * t)
        b = int(78 * (1-t) + 22 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))
    
    bg = bg.convert('RGBA')
    
    # 2. Rounded mask
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=CORNER_RADIUS, fill=255)
    bg.putalpha(mask)
    
    # 3. Letters
    letters = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    l_draw = ImageDraw.Draw(letters)
    
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
    so = int(SIZE * 0.016)
    l_draw.text((wx + so, cy + so), "W", font=font, fill=(0, 0, 0, 100), anchor="mm")
    l_draw.text((mx + so, cy + so), "M", font=font, fill=(0, 0, 0, 100), anchor="mm")
    
    # Vibrant colors
    l_draw.text((wx, cy), "W", font=font, fill=(85, 165, 255, 255), anchor="mm")
    l_draw.text((mx, cy), "M", font=font, fill=(255, 100, 160, 255), anchor="mm")
    
    img = Image.alpha_composite(bg, letters)
    
    # 4. Strong glass highlights
    glass = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    g_draw = ImageDraw.Draw(glass)
    
    # Stronger top edge highlight (Liquid Glass specular)
    for i in range(4):
        a = 160 - i * 40
        g_draw.rounded_rectangle([i, i, SIZE-1-i, SIZE-1-i], radius=CORNER_RADIUS-i, 
                                outline=(255, 255, 255, a), width=1)
    
    # Stronger top reflection
    rh = int(SIZE * 0.45)
    for y in range(rh):
        if y < SIZE * 0.08:
            a = int(70 * (1 - y/(SIZE*0.08)))
        elif y < SIZE * 0.2:
            a = int(35 * (1 - (y-SIZE*0.08)/(SIZE*0.12)))
        else:
            a = int(15 * (1 - (y-SIZE*0.2)/(rh-SIZE*0.2)))
        g_draw.line([(0, y), (SIZE, y)], fill=(255, 255, 255, a))
    
    # Bottom shadow
    sh = int(SIZE * 0.12)
    for y in range(SIZE - sh, SIZE):
        p = (y - (SIZE - sh)) / sh
        g_draw.line([(0, y), (SIZE, y)], fill=(0, 0, 0, int(65 * p)))
    
    # Side shadows for depth
    sw = int(SIZE * 0.025)
    for x in range(sw):
        a = int(25 * (1 - x/sw))
        g_draw.line([(x, 0), (x, SIZE)], fill=(0, 0, 0, a))
        g_draw.line([(SIZE-1-x, 0), (SIZE-1-x, SIZE)], fill=(0, 0, 0, a))
    
    return Image.alpha_composite(img, glass)

# Generate
sizes = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

print("Generating enhanced glass icon...")
master = create_icon()
out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"

for fn, ps in sizes:
    master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
    print(f"  ✓ {fn}")

master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Glass.png')
print("\n✅ Done!")
