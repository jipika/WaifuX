from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import zipfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
DESIGN_DIR = ROOT / "Design"
LOGO_DIR = DESIGN_DIR / "Logo"
APPICON_DIR = ROOT / "Assets.xcassets" / "AppIcon.appiconset"
READY_DIR = DESIGN_DIR / "AppIcon-Ready"
ARCHIVE_PATH = DESIGN_DIR / "AppIcon-Ready.zip"

MASTER_PATH = DESIGN_DIR / "WallHaven-AppIcon-master.png"
PREVIEW_PATH = DESIGN_DIR / "AppIcon-preview.png"
SIZE_CHECK_PATH = DESIGN_DIR / "AppIcon-size-check.png"
SIZE_SHEET_PATH = DESIGN_DIR / "WallHaven-AppIcon-size-sheet.png"
FOCUS_PREVIEW_PATH = DESIGN_DIR / "WallHaven-AppIcon-focus-preview.png"
PHILOSOPHY_PATH = DESIGN_DIR / "WallHaven-AppIcon-Philosophy.md"

LOGO_EXPORTS = {
    "AppIcon.png": 1024,
    "AppIcon_Final.png": 1024,
    "AppIcon_Final_1024.png": 1024,
    "AppIcon_Glass.png": 1024,
    "AppIcon_512.png": 512,
    "AppIcon_256.png": 256,
    "AppIcon_128.png": 128,
    "WallHaven_AppIcon.png": 1024,
    "WallHaven_AppIcon_256.png": 256,
    "WallHaven_AppIcon_128.png": 128,
}


def rgba(hex_value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    hex_value = hex_value.lstrip("#")
    return (
        int(hex_value[0:2], 16),
        int(hex_value[2:4], 16),
        int(hex_value[4:6], 16),
        alpha,
    )


def lerp_color(
    a: tuple[int, int, int, int],
    b: tuple[int, int, int, int],
    t: float,
) -> tuple[int, int, int, int]:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def vertical_gradient(
    size: tuple[int, int],
    top: tuple[int, int, int, int],
    bottom: tuple[int, int, int, int],
) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    draw = ImageDraw.Draw(image)
    denominator = max(height - 1, 1)
    for y in range(height):
        t = y / denominator
        draw.line([(0, y), (width, y)], fill=lerp_color(top, bottom, t))
    return image


def diagonal_gradient(
    size: tuple[int, int],
    top_left: tuple[int, int, int, int],
    bottom_right: tuple[int, int, int, int],
) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    pixels = image.load()
    denominator = max(width + height - 2, 1)
    for y in range(height):
        for x in range(width):
            t = (x + y) / denominator
            pixels[x, y] = lerp_color(top_left, bottom_right, t)
    return image


def radial_glow(
    size: tuple[int, int],
    center: tuple[int, int],
    radius: int,
    color: tuple[int, int, int, int],
    blur: int,
) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = center
    draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    return layer.filter(ImageFilter.GaussianBlur(blur))


def rounded_mask(size: tuple[int, int], radius: int, inset: int = 0) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (inset, inset, size[0] - inset - 1, size[1] - inset - 1),
        radius=radius,
        fill=255,
    )
    return mask


def apply_mask(image: Image.Image, mask: Image.Image) -> Image.Image:
    masked = Image.new("RGBA", image.size, (0, 0, 0, 0))
    masked.paste(image, (0, 0), mask)
    return masked


def scaled_points(
    points: list[tuple[int, int]],
    scale: float,
    dx: float = 0.0,
    dy: float = 0.0,
) -> list[tuple[int, int]]:
    return [(int(round(x * scale + dx)), int(round(y * scale + dy))) for x, y in points]


def cubic_bezier_points(
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    steps: int = 40,
) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for index in range(steps + 1):
        t = index / steps
        mt = 1 - t
        x = (
            mt * mt * mt * p0[0]
            + 3 * mt * mt * t * p1[0]
            + 3 * mt * t * t * p2[0]
            + t * t * t * p3[0]
        )
        y = (
            mt * mt * mt * p0[1]
            + 3 * mt * mt * t * p1[1]
            + 3 * mt * t * t * p2[1]
            + t * t * t * p3[1]
        )
        points.append((x, y))
    return points


def build_w_curve_points(scale: float, dx: float = 0.0, dy: float = 0.0) -> list[tuple[int, int]]:
    curves = [
        ((184, 214), (176, 308), (214, 548), (286, 648)),
        ((286, 648), (332, 624), (362, 426), (414, 330)),
        ((414, 330), (468, 426), (498, 624), (544, 648)),
        ((544, 648), (616, 548), (654, 308), (646, 214)),
    ]

    sampled: list[tuple[float, float]] = []
    for index, curve in enumerate(curves):
        points = cubic_bezier_points(*curve, steps=26)
        if index > 0:
            points = points[1:]
        sampled.extend(points)

    return [
        (int(round(x * scale + dx)), int(round(y * scale + dy)))
        for x, y in sampled
    ]


def line_mask(size: int, points: list[tuple[int, int]], width: int) -> Image.Image:
    oversample = 4
    large_size = size * oversample
    large_points = [(x * oversample, y * oversample) for x, y in points]
    large_width = width * oversample

    mask = Image.new("L", (large_size, large_size), 0)
    draw = ImageDraw.Draw(mask)
    draw.line(large_points, fill=255, width=large_width, joint="curve")

    cap_radius = large_width // 2
    for px, py in (large_points[0], large_points[-1]):
        draw.ellipse(
            (px - cap_radius, py - cap_radius, px + cap_radius, py + cap_radius),
            fill=255,
        )

    return mask.resize((size, size), Image.Resampling.LANCZOS)


def alpha_from_mask(mask: Image.Image, blur_radius: int, alpha_scale: float) -> Image.Image:
    alpha = mask.filter(ImageFilter.GaussianBlur(blur_radius))
    return alpha.point(lambda value: int(value * alpha_scale))


def draw_glass_w(size: int, simplified: bool) -> Image.Image:
    scale = size / 828
    points = build_w_curve_points(scale)
    stroke_width = int(round((128 if simplified else 116) * scale))
    mask = line_mask(size, points, stroke_width)

    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Tight contact shadow to keep the object seated on the tile.
    shadow_mask = ImageChops.offset(mask, 0, max(8, int(round(18 * scale))))
    shadow_alpha = alpha_from_mask(shadow_mask, max(10, int(round(18 * scale))), 0.34 if simplified else 0.42)
    shadow = Image.new("RGBA", (size, size), rgba("0B0D14", 0))
    shadow.putalpha(shadow_alpha)
    result.alpha_composite(shadow)

    # Colored glow around the glass body.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.34)), int(round(size * 0.34))),
            int(round(size * 0.18)),
            rgba("B7F07B", 88 if simplified else 108),
            int(round(size * 0.09)),
        )
    )
    glow.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.66)), int(round(size * 0.30))),
            int(round(size * 0.18)),
            rgba("FF6D77", 92 if simplified else 116),
            int(round(size * 0.10)),
        )
    )
    glow.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.50)), int(round(size * 0.58))),
            int(round(size * 0.28)),
            rgba("2E7EFF", 126 if simplified else 146),
            int(round(size * 0.12)),
        )
    )
    glow_mask = alpha_from_mask(mask, max(16, int(round(28 * scale))), 0.74 if simplified else 0.82)
    glow.putalpha(ImageChops.multiply(glow.getchannel("A"), glow_mask))
    result.alpha_composite(glow)

    # Main glass fill.
    fill = vertical_gradient((size, size), rgba("8FE9A6"), rgba("2F76FF"))
    fill.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.34)), int(round(size * 0.30))),
            int(round(size * 0.16)),
            rgba("BDFC8C", 150 if simplified else 178),
            int(round(size * 0.07)),
        )
    )
    fill.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.68)), int(round(size * 0.28))),
            int(round(size * 0.15)),
            rgba("FF7E8A", 158 if simplified else 186),
            int(round(size * 0.07)),
        )
    )
    fill.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.50)), int(round(size * 0.50))),
            int(round(size * 0.22)),
            rgba("FFFFFF", 38 if simplified else 52),
            int(round(size * 0.10)),
        )
    )
    fill.alpha_composite(
        diagonal_gradient((size, size), rgba("FFFFFF", 44), rgba("1C3EAE", 0))
    )
    glass = apply_mask(fill, mask)

    # Full inner reflective groove across the whole W body.
    inner_track_mask = line_mask(
        size,
        build_w_curve_points(scale, dy=-int(round(10 * scale))),
        int(round((18 if simplified else 16) * scale)),
    )
    inner_shadow = Image.new("RGBA", (size, size), rgba("4E6EA7", 34 if simplified else 42))
    glass.alpha_composite(apply_mask(inner_shadow, inner_track_mask))

    inner_highlight_mask = line_mask(
        size,
        build_w_curve_points(scale, dy=-int(round(14 * scale))),
        int(round((10 if simplified else 8) * scale)),
    )
    inner_highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner_highlight.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.50)), int(round(size * 0.26))),
            int(round(size * 0.24)),
            rgba("FFFFFF", 92 if simplified else 118),
            int(round(size * 0.08)),
        )
    )
    inner_highlight.alpha_composite(
        vertical_gradient((size, size), rgba("FFFFFF", 54 if simplified else 68), rgba("FFFFFF", 0))
    )
    glass.alpha_composite(apply_mask(inner_highlight, inner_highlight_mask))

    # Inner specular sweep.
    specular_mask = line_mask(
        size,
        build_w_curve_points(scale, dx=0.0, dy=-int(round(8 * scale))),
        int(round((32 if simplified else 28) * scale)),
    )
    specular = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    specular.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.49)), int(round(size * 0.26))),
            int(round(size * 0.22)),
            rgba("FFFFFF", 132 if simplified else 156),
            int(round(size * 0.09)),
        )
    )
    glass.alpha_composite(apply_mask(specular, specular_mask))

    # Crisp rim and subtle top-left edge light.
    rim = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rim_mask = line_mask(size, points, int(round((stroke_width + 8) * 1.02)))
    rim_alpha = alpha_from_mask(rim_mask, max(2, int(round(3 * scale))), 1.0)
    rim.putalpha(rim_alpha)
    rim_tint = vertical_gradient((size, size), rgba("FFFFFF", 24 if simplified else 34), rgba("FFFFFF", 10))
    glass.alpha_composite(apply_mask(rim_tint, rim_alpha))

    edge_light_mask = line_mask(
        size,
        build_w_curve_points(scale, dx=-int(round(4 * scale)), dy=-int(round(10 * scale))),
        int(round((16 if simplified else 14) * scale)),
    )
    edge_light = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    edge_light.alpha_composite(
        radial_glow(
            (size, size),
            (int(round(size * 0.48)), int(round(size * 0.20))),
            int(round(size * 0.22)),
            rgba("FFFFFF", 120 if simplified else 148),
            int(round(size * 0.06)),
        )
    )
    glass.alpha_composite(apply_mask(edge_light, edge_light_mask))

    result.alpha_composite(glass)
    return result


def build_tile(size: int = 1024, simplified: bool = False) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    scale = size / 1024

    tile_size = int(round(824 * scale))
    tile_radius = int(round(184 * scale))

    tile_shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile_shadow_draw = ImageDraw.Draw(tile_shadow)
    tile_shadow_draw.rounded_rectangle(
        (
            int(round(112 * scale)),
            int(round(122 * scale)),
            int(round(912 * scale)),
            int(round(922 * scale)),
        ),
        radius=int(round(186 * scale)),
        fill=(0, 0, 0, 170 if simplified else 190),
    )
    canvas.alpha_composite(tile_shadow.filter(ImageFilter.GaussianBlur(max(18, int(round(30 * scale))))))

    tile = vertical_gradient((tile_size, tile_size), rgba("333333"), rgba("181818"))
    tile.alpha_composite(
        diagonal_gradient((tile_size, tile_size), rgba("3B3B3B", 18), rgba("111111", 0))
    )
    tile.alpha_composite(
        radial_glow(
            (tile_size, tile_size),
            (int(round(tile_size * 0.24)), int(round(tile_size * 0.12))),
            int(round(tile_size * 0.22)),
            rgba("FFFFFF", 20 if simplified else 26),
            int(round(tile_size * 0.08)),
        )
    )
    tile.alpha_composite(
        vertical_gradient((tile_size, tile_size), (0, 0, 0, 0), (0, 0, 0, 34))
    )

    symbol_layer = draw_glass_w(tile_size, simplified)
    tile.alpha_composite(symbol_layer)

    top_sheen = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(top_sheen)
    sheen_draw.rounded_rectangle(
        (
            int(round(tile_size * 0.10)),
            int(round(tile_size * 0.05)),
            int(round(tile_size * 0.90)),
            int(round(tile_size * 0.32)),
        ),
        radius=int(round(tile_size * 0.18)),
        fill=(255, 255, 255, 14 if simplified else 18),
    )
    tile.alpha_composite(top_sheen.filter(ImageFilter.GaussianBlur(max(10, int(round(tile_size * 0.03))))))

    tile_mask = rounded_mask((tile_size, tile_size), tile_radius)
    tile = apply_mask(tile, tile_mask)

    border = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    border_draw = ImageDraw.Draw(border)
    border_draw.rounded_rectangle(
        (1, 1, tile_size - 2, tile_size - 2),
        radius=tile_radius,
        outline=(255, 255, 255, 32 if simplified else 38),
        width=max(2, int(round(3 * scale))),
    )
    border_draw.rounded_rectangle(
        (4, 4, tile_size - 5, tile_size - 5),
        radius=max(4, tile_radius - int(round(4 * scale))),
        outline=(0, 0, 0, 18),
        width=max(1, int(round(2 * scale))),
    )
    tile.alpha_composite(border)

    tile_inset = int(round(100 * scale))
    canvas.alpha_composite(tile, (tile_inset, tile_inset))
    return canvas


def resize_icon(master: Image.Image, target_size: int) -> Image.Image:
    resized = master.resize((target_size, target_size), Image.Resampling.LANCZOS)
    if target_size <= 32:
        return resized.filter(ImageFilter.UnsharpMask(radius=1.2, percent=190, threshold=2))
    if target_size <= 64:
        return resized.filter(ImageFilter.UnsharpMask(radius=1.1, percent=165, threshold=2))
    if target_size <= 256:
        return resized.filter(ImageFilter.UnsharpMask(radius=1.0, percent=130, threshold=2))
    return resized


def save_icon_set(master: Image.Image, simplified_master: Image.Image) -> None:
    size_map = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for filename, target_size in size_map.items():
        source = simplified_master if target_size <= 64 else master
        resize_icon(source, target_size).save(APPICON_DIR / filename)


def save_logo_exports(master: Image.Image) -> None:
    for filename, target_size in LOGO_EXPORTS.items():
        resize_icon(master, target_size).save(LOGO_DIR / filename)


def build_size_check(master: Image.Image, simplified_master: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (980, 290), rgba("14171D"))
    draw = ImageDraw.Draw(canvas)
    panel_x = [30, 260, 490, 740]
    labels = [1024, 512, 128, 32]
    display_sizes = [162, 162, 92, 32]

    for x, label, display_size in zip(panel_x, labels, display_sizes):
        draw.rounded_rectangle((x, 30, x + 220, 250), radius=24, fill=rgba("1C2028"))
        source = simplified_master if label <= 64 else master
        icon = resize_icon(source, label).resize((display_size, display_size), Image.Resampling.LANCZOS)
        canvas.alpha_composite(icon, (x + (220 - display_size) // 2, 52 + (162 - display_size) // 2))
        draw.text((x + 92, 236), str(label), fill=rgba("D8DEE8"))

    return canvas


def build_size_sheet(master: Image.Image, simplified_master: Image.Image) -> Image.Image:
    card_width = 132
    gap = 18
    margin = 24
    sizes = [1024, 512, 256, 128, 64, 32, 16]
    width = margin * 2 + card_width * len(sizes) + gap * (len(sizes) - 1)
    canvas = Image.new("RGBA", (width, 160), rgba("0F1218"))
    draw = ImageDraw.Draw(canvas)

    for index, target_size in enumerate(sizes):
        left = margin + index * (card_width + gap)
        draw.rounded_rectangle((left, 18, left + card_width, 150), radius=20, fill=rgba("171C24"))
        source = simplified_master if target_size <= 64 else master
        icon = resize_icon(source, target_size)
        preview_size = 94
        resample = Image.Resampling.NEAREST if target_size <= 64 else Image.Resampling.LANCZOS
        icon = icon.resize((preview_size, preview_size), resample)
        canvas.alpha_composite(icon, (left + 19, 28))
        draw.text((left + 44, 126), str(target_size), fill=rgba("D7DEE9"))

    return canvas


def build_focus_preview(master: Image.Image, simplified_master: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (1180, 220), rgba("101319"))
    draw = ImageDraw.Draw(canvas)
    sizes = [1024, 512, 256, 128, 64, 32, 16]
    x = 24
    for target_size in sizes:
        draw.rounded_rectangle((x, 26, x + 138, 194), radius=22, fill=rgba("171B23"))
        source = simplified_master if target_size <= 64 else master
        icon = resize_icon(source, target_size).resize((92, 92), Image.Resampling.LANCZOS)
        canvas.alpha_composite(icon, (x + 23, 44))
        draw.text((x + 50, 156), str(target_size), fill=rgba("D6DDE8"))
        x += 162
    return canvas


def package_ready_outputs() -> None:
    if READY_DIR.exists():
        shutil.rmtree(READY_DIR)
    READY_DIR.mkdir(parents=True, exist_ok=True)

    previews_dir = READY_DIR / "Previews"
    previews_dir.mkdir(parents=True, exist_ok=True)

    for source in [
        MASTER_PATH,
        PREVIEW_PATH,
        SIZE_CHECK_PATH,
        SIZE_SHEET_PATH,
        FOCUS_PREVIEW_PATH,
        PHILOSOPHY_PATH,
    ]:
        target = READY_DIR / source.name if source.suffix == ".md" else previews_dir / source.name
        shutil.copy2(source, target)

    logo_exports_dir = READY_DIR / "LogoExports"
    logo_exports_dir.mkdir(parents=True, exist_ok=True)
    for filename in LOGO_EXPORTS:
        source = LOGO_DIR / filename
        if source.exists():
            shutil.copy2(source, logo_exports_dir / filename)

    packaged_appiconset = READY_DIR / "AppIcon.appiconset"
    shutil.copytree(APPICON_DIR, packaged_appiconset)

    iconset_dir = READY_DIR / "WallHaven.iconset"
    shutil.copytree(APPICON_DIR, iconset_dir)
    contents_path = iconset_dir / "Contents.json"
    if contents_path.exists():
        contents_path.unlink()

    iconutil = shutil.which("iconutil")
    if iconutil:
        subprocess.run(
            [iconutil, "-c", "icns", str(iconset_dir), "-o", str(READY_DIR / "WallHaven.icns")],
            check=False,
        )

    with zipfile.ZipFile(ARCHIVE_PATH, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in READY_DIR.rglob("*"):
            archive.write(path, path.relative_to(READY_DIR.parent))


def main() -> None:
    DESIGN_DIR.mkdir(parents=True, exist_ok=True)
    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    APPICON_DIR.mkdir(parents=True, exist_ok=True)

    master = build_tile()
    simplified_master = build_tile(simplified=True)

    master.save(MASTER_PATH)
    master.save(PREVIEW_PATH)
    save_icon_set(master, simplified_master)
    save_logo_exports(master)
    build_size_check(master, simplified_master).save(SIZE_CHECK_PATH)
    build_size_sheet(master, simplified_master).save(SIZE_SHEET_PATH)
    build_focus_preview(master, simplified_master).save(FOCUS_PREVIEW_PATH)
    package_ready_outputs()

    print(f"Generated app icon master: {MASTER_PATH}")
    print(f"Updated icon set in: {APPICON_DIR}")
    print(f"Packaged ready-to-use assets in: {READY_DIR}")
    print(f"Created archive: {ARCHIVE_PATH}")


if __name__ == "__main__":
    main()
