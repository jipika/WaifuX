from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
RADIUS = int(SIZE * 0.22)

def create_icon():
    # Create base
    img = Image.new('RGBA', (SIZE, SIZE), (18, 20, 26, 255))
    draw = ImageDraw.Draw(img)
    
    # Gradient background
    for y in range(SIZE):
        t = y / SIZE
        r = int(55 * (1-t) + 15 * t)
        g = int(60 * (1-t) + 17 * t)
        b = int(75 * (1-t) + 20 * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))
    
    # Mask
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=RADIUS, fill=255)
    img.putalpha(mask)
    
    # Load font
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
    draw.text((wx + so, cy + so), "W", font=font, fill=(0, 0, 0, 80), anchor="mm")
    draw.text((mx + so, cy + so), "M", font=font, fill=(0, 0, 0, 80), anchor="mm")
    
    # Vibrant colors - NO transparency
    w_color = (90, 170, 255, 255)    # Bright blue
    m_color = (255, 100, 160, 255)   # Bright pink
    
    # Draw solid letters
    draw.text((wx, cy), "W", font=font, fill=w_color, anchor="mm")
    draw.text((mx, cy), "M", font=font, fill=m_color, anchor="mm")
    
    # Highlights on letters
    ho = -int(SIZE * 0.003)
    draw.text((wx + ho, cy + ho), "W", font=font, fill=(200, 230, 255, 90), anchor="mm")
    draw.text((mx + ho, cy + ho), "M", font=font, fill=(255, 220, 240, 70), anchor="mm")
    
    # Glass highlights
    glass = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    
    # Top edge highlight
    for i in range(4):
        a = 130 - i * 30
        gd.rounded_rectangle([i, i, SIZE-1-i, SIZE-1-i], radius=RADIUS-i, outline=(255, 255, 255, a), width=1)
    
    # Top shine
    rh = int(SIZE * 0.4)
    for y in range(rh):
        if y < SIZE * 0.08:
            a = int(45 * (1 - y/(SIZE*0.08)))
        else:
            a = int(18 * (1 - (y-SIZE*0.08)/(rh-SIZE*0.08)))
        gd.line([(0, y), (SIZE, y)], fill=(255, 255, 255, a))
    
    # Bottom shadow
    sh = int(SIZE * 0.12)
    for y in range(SIZE - sh, SIZE):
        p = (y - (SIZE - sh)) / sh
        gd.line([(0, y), (SIZE, y)], fill=(0, 0, 0, int(60 * p)))
    
    return Image.alpha_composite(img, glass)

# Generate all sizes
sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
         (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), 
         (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]

print("Generating...")
master = create_icon()
out = "/Volumes/mac/CodeLibrary/Claude/WallHaven/Assets.xcassets/AppIcon.appiconset"

for ps, fn in sizes:
    master.resize((ps, ps), Image.Resampling.LANCZOS).save(f'{out}/{fn}.png')
    print(f"  {fn}")

master.save('/Volumes/mac/CodeLibrary/Claude/WallHaven/Design/Logo/AppIcon_Final.png')
print("Done!")
