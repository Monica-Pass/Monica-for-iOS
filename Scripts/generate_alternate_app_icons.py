#!/usr/bin/env python3
"""生成 Monica 的备用 App 图标（可复现）。

用法：
    python3 Scripts/generate_alternate_app_icons.py

产物（1024×1024、RGB、无 alpha，符合 App Store / asset catalog 要求）：
    App/MonicaApp/Assets.xcassets/AppIconMidnight.appiconset/
    App/MonicaApp/Assets.xcassets/AppIconAurora.appiconset/

图标集名称必须与 MonicaCore 的 AlternateAppIcon rawValue、以及工程里的
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES 保持一致。改名字要三处一起改。
脚本只依赖 Pillow 与 numpy，重复运行输出一致（无随机数）。
"""

from __future__ import annotations

import json
import math
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "App" / "MonicaApp" / "Assets.xcassets"
SIZE = 1024
SS = 4  # 超采样倍率，边缘更干净

ICON_SETS = {
    "AppIconMidnight": {
        "background_top": "#050A1A",
        "background_bottom": "#141E3C",
        "description": "深蓝夜色与金色钥匙孔",
    },
    "AppIconAurora": {
        "background_top": "#03100C",
        "background_bottom": "#0B2A24",
        "description": "墨绿极光与薄荷钥匙孔",
    },
}


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def gradient_background(top: str, bottom: str) -> Image.Image:
    top_rgb = np.array(hex_rgb(top), dtype=np.float32)
    bottom_rgb = np.array(hex_rgb(bottom), dtype=np.float32)
    t = np.linspace(0.0, 1.0, SIZE, dtype=np.float32)[:, None, None]
    rgb = top_rgb * (1.0 - t) + bottom_rgb * t
    rgb = np.repeat(rgb, SIZE, axis=1)
    return Image.fromarray(rgb.round().astype(np.uint8), mode="RGB")


def radial_glow(size: int, center: tuple[float, float], radius: float, color: str, strength: float) -> Image.Image:
    """返回一张带透明度的径向光晕。"""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    dist = np.sqrt((xx - center[0]) ** 2 + (yy - center[1]) ** 2)
    falloff = np.clip(1.0 - dist / radius, 0.0, 1.0) ** 2
    alpha = (falloff * strength * 255).round().astype(np.uint8)
    rgb = np.zeros((size, size, 3), dtype=np.uint8)
    rgb[:, :] = hex_rgb(color)
    return Image.fromarray(np.dstack([rgb, alpha]), mode="RGBA")


def draw_keyhole(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], color: str, shadow: str | None = None) -> None:
    """经典钥匙孔：圆头 + 圆角矩形柄。box 为整个钥匙孔外接框（超采样坐标）。"""
    x0, y0, x1, y1 = box
    width = x1 - x0
    height = y1 - y0
    head_d = width * 0.55
    head_center = (x0 + width / 2, y0 + head_d / 2)
    stem_w = head_d * 0.34
    stem_top = y0 + head_d * 0.55
    stem_bottom = y1

    def paint(offset: tuple[float, float], fill: str) -> None:
        dx, dy = offset
        cx = head_center[0] + dx
        cy = head_center[1] + dy
        draw.ellipse(
            [cx - head_d / 2, cy - head_d / 2, cx + head_d / 2, cy + head_d / 2],
            fill=fill,
        )
        draw.rounded_rectangle(
            [
                cx - stem_w / 2,
                stem_top + dy,
                cx + stem_w / 2,
                stem_bottom + dy,
            ],
            radius=stem_w / 2,
            fill=fill,
        )

    if shadow:
        paint((width * 0.035, height * 0.045), shadow)
    paint((0, 0), color)


def draw_aurora_ribbons(layer: Image.Image) -> None:
    """三条柔和的极光波带：正弦曲线描边 + 高斯模糊，只覆盖画面上部。"""
    size = layer.size[0]
    ribbons = [
        ("#2EE6C0", 0.30, 0.055, 210, 0.0, 1.0),
        ("#5FE0FF", 0.40, 0.045, 160, 1.7, 0.8),
        ("#A78BFA", 0.50, 0.040, 120, 0.6, 0.75),
    ]
    for color, base, amplitude, width, phase, strength in ribbons:
        band = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(band)
        points = []
        steps = 240
        for i in range(steps + 1):
            x = -0.10 + 1.20 * i / steps
            y = base + amplitude * math.sin(2 * math.pi * (x * 1.35 + phase))
            points.append((x * size, y * size))
        alpha = int(255 * strength)
        draw.line(points, fill=hex_rgb(color) + (alpha,), width=width, joint="curve")
        band = band.rotate(-9, center=(size / 2, size / 2), resample=Image.BICUBIC)
        band = band.filter(ImageFilter.GaussianBlur(width * 0.55))
        # 只让光带覆盖画面上半部分，底部保持干净。
        mask = Image.new("L", (size, size), 0)
        mask_draw = ImageDraw.Draw(mask)
        mask_draw.rectangle([0, 0, size, size * 0.78], fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(size * 0.06))
        layer.alpha_composite(Image.composite(band, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask))


def build_midnight() -> Image.Image:
    icon = gradient_background("#050A1A", "#141E3C").convert("RGBA")
    glow = radial_glow(SIZE, (SIZE * 0.5, SIZE * 0.52), SIZE * 0.46, "#2E4C8A", 0.55)
    icon = Image.alpha_composite(icon, glow)

    size = SIZE * SS
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    margin = size * 0.22
    draw_keyhole(
        draw,
        (margin, margin, size - margin, size - margin),
        "#F4C45B",
        shadow="#B98516",
    )
    layer = layer.resize((SIZE, SIZE), Image.LANCZOS)
    icon = Image.alpha_composite(icon, layer)
    return icon.convert("RGB")


def build_aurora() -> Image.Image:
    icon = gradient_background("#03100C", "#0B2A24").convert("RGBA")

    size = SIZE * SS
    ribbons = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_aurora_ribbons(ribbons)
    icon = Image.alpha_composite(icon, ribbons.resize((SIZE, SIZE), Image.LANCZOS))

    glow = radial_glow(SIZE, (SIZE * 0.5, SIZE * 0.56), SIZE * 0.4, "#0E5F52", 0.45)
    icon = Image.alpha_composite(icon, glow)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    margin = size * 0.22
    draw_keyhole(
        draw,
        (margin, margin, size - margin, size - margin),
        "#B8FBEA",
        shadow="#1B7F6C",
    )
    layer = layer.resize((SIZE, SIZE), Image.LANCZOS)
    icon = Image.alpha_composite(icon, layer)
    return icon.convert("RGB")


CONTENTS = {
    "images": [
        {
            "filename": "Icon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ],
    "info": {"author": "xcode", "version": 1},
}


def write_icon_set(name: str, image: Image.Image) -> None:
    assert image.size == (SIZE, SIZE), image.size
    assert image.mode == "RGB", image.mode
    directory = ASSETS / f"{name}.appiconset"
    directory.mkdir(parents=True, exist_ok=True)
    png_path = directory / "Icon-1024.png"
    image.save(png_path, format="PNG", optimize=True)
    (directory / "Contents.json").write_text(json.dumps(CONTENTS, indent=2) + "\n", encoding="utf-8")
    print(f"{name}: {png_path.relative_to(ROOT)} mode={image.mode} size={image.size} bytes={png_path.stat().st_size}")


def main() -> int:
    builders = {"AppIconMidnight": build_midnight, "AppIconAurora": build_aurora}
    for name, meta in ICON_SETS.items():
        image = builders[name]()
        write_icon_set(name, image)
        print(f"  {meta['description']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
