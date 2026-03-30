from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
RADIUS = int(SIZE * 0.22)

# Vibrant colors
W_BLUE = (85, 165, 255)      # Bright blue
M_PINK = (255, 100, 160)     # Bright pink

def create_icon():
    # 1. Create background
    bg = Image.new('RGB', (SIZE, SIZE), (15, 17, 22))
    draw = ImageDraw.Draw(bg)
    
    # Gradient
    for y in range(SIZE):
        t = y / SIZE
        r = int(50 * (1-t) + 15 * t)
        g = int(55 * (1-t) + 17 * t)
        b = int(70 * (1-t) + 22 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))
    
    # 2. Apply rounded mask
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=RADIUS, fill=255)
    bg = bg.convert('RGBA')
    bg.putalpha(mask)
    
    # 3. Create letters layer
    letters = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    l_draw = ImageDraw.Draw(letters)
    
    # Load font
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SF-Pro-Display-Heavy.otf", int(SIZE * 0.44))
    except:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(SIZE * 0.44))
        except:
            font = ImageFont.load_default()
    
    cy = SIZE // 2 + int(SIZE * 0.015)
    wx = SIZE // 2 - int(SIZE * 0.06)
    mx = SIZE // 2 + int(SIZE * 0.06)
    
    # Shadow
    so = int(SIZE * 0.012)
    l_draw.text((wx + so, cy + so), "W", font=font, fill=(0, 0, 0, 100), anchor="mm")
    l_draw.text((mx + so, cy + so), "M", font=font, fill=(0, 0, 0, 100), anchor="mm")
    
    # Main letters - NO transparency, solid colors
    l_draw.text((wx, cy), "W", font=font, fill=(*W_BLUE, 255), anchor="mm")
    l_draw.text((mx, cy), "M", font=font, fill=(*M_PINK, 255), anchor="mm")
    
    # 4. Composite letters onto background
    img = Image.alpha_composite(bg, letters)
    
    # 5. Add glass highlights (separate layer)
    glass = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    g_draw = ImageDraw.Draw(glass)
    
    # Top edge highlight
    for i in range(3):
        a = 140 - i * 40
        g_draw.rounded_rectangle([i, i, SIZE-1-i, SIZE-1-i], radius=RADIUS-i, 
                                outline=(255, 255, 255, a), width=1)
    
    # Top shine
    rh = int(SIZE * 0.35)
    for y in range(rh):
        if y < SIZE * 0.06:
            a = int(55 * (1 - y/(SIZE*0.06)))
        else:
            a = int(22 * (1 - (y-SIZE*0.06)/(rh-SIZE*0.06)))
        g_draw.line([(0, y), (SIZE, y)], fill=(255, 255, 255, a))
    
    # Bottom shadow
    sh = int(SIZE * 0.12)
    for y in range(SIZE - sh, SIZE):
        p = (y - (SIZE - sh)) / sh
        g_draw.line([(0, y), (SIZE, y)], fill=(0, 0, 0, int(55 * p)))
    
    return Image.alpha_composite(img, glass)

# Generate all sizes
sizes = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

print("Generating vibrant icons...")
master = create_icon()
out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"

for fn, ps in sizes:
    master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
    print(f"  {fn}")

master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Vibrant.png')
print("Done!")
