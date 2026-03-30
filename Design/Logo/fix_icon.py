from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
RADIUS = int(SIZE * 0.22)

def create_icon():
    # 1. Create solid background first
    bg = Image.new('RGB', (SIZE, SIZE), (18, 20, 26))
    draw = ImageDraw.Draw(bg)
    
    # Gradient on RGB background
    for y in range(SIZE):
        t = y / SIZE
        r = int(55 * (1-t) + 15 * t)
        g = int(60 * (1-t) + 17 * t)
        b = int(75 * (1-t) + 20 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))
    
    # Convert to RGBA for compositing
    bg = bg.convert('RGBA')
    
    # 2. Create mask for rounded corners
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=RADIUS, fill=255)
    
    # Apply mask to background
    bg.putalpha(mask)
    
    # 3. Create letters layer
    letters = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(letters)
    
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SF-Pro-Display-Heavy.otf", int(SIZE * 0.42))
    except:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(SIZE * 0.42))
        except:
            font = ImageFont.load_default()
    
    cy = SIZE // 2 + int(SIZE * 0.01)
    wx = SIZE // 2 - int(SIZE * 0.055)
    mx = SIZE // 2 + int(SIZE * 0.055)
    
    # Shadows
    so = int(SIZE * 0.01)
    draw.text((wx + so, cy + so), "W", font=font, fill=(0, 0, 0, 90), anchor="mm")
    draw.text((mx + so, cy + so), "M", font=font, fill=(0, 0, 0, 90), anchor="mm")
    
    # Vibrant solid colors
    w_color = (90, 170, 255, 255)
    m_color = (255, 100, 160, 255)
    
    draw.text((wx, cy), "W", font=font, fill=w_color, anchor="mm")
    draw.text((mx, cy), "M", font=font, fill=m_color, anchor="mm")
    
    # Highlights
    ho = -int(SIZE * 0.003)
    draw.text((wx + ho, cy + ho), "W", font=font, fill=(255, 255, 255, 100), anchor="mm")
    draw.text((mx + ho, cy + ho), "M", font=font, fill=(255, 255, 255, 80), anchor="mm")
    
    # 4. Composite letters onto background
    img = Image.alpha_composite(bg, letters)
    
    # 5. Add glass highlights layer
    glass = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    
    # Top edge highlight
    for i in range(4):
        a = 140 - i * 35
        gd.rounded_rectangle([i, i, SIZE-1-i, SIZE-1-i], radius=RADIUS-i, 
                            outline=(255, 255, 255, a), width=1)
    
    # Top shine gradient
    rh = int(SIZE * 0.35)
    for y in range(rh):
        if y < SIZE * 0.06:
            a = int(50 * (1 - y/(SIZE*0.06)))
        else:
            a = int(20 * (1 - (y-SIZE*0.06)/(rh-SIZE*0.06)))
        gd.line([(0, y), (SIZE, y)], fill=(255, 255, 255, a))
    
    # Bottom shadow
    sh = int(SIZE * 0.1)
    for y in range(SIZE - sh, SIZE):
        p = (y - (SIZE - sh)) / sh
        gd.line([(0, y), (SIZE, y)], fill=(0, 0, 0, int(50 * p)))
    
    return Image.alpha_composite(img, glass)

# Generate
sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
         (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), 
         (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]

print("Fixing icon...")
master = create_icon()
out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"

for ps, fn in sizes:
    master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
    print(f"  {fn}")

master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Final.png')
print("Done!")
