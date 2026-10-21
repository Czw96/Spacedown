#!/usr/bin/env python3
"""生成带 Finder 布局的安装 dmg。

“大厂那种好看”不是 dmg 格式自带的，而是 `.DS_Store` 里的窗口元数据：窗口大小、
图标坐标、背景图、图标尺寸。dmgbuild 直接写这些元数据（不经过 Finder 自动化），
所以在命令行/沙箱里也能稳定生成。

依赖（只影响打包，不影响 App）：
    pip install dmgbuild pillow

用法：
    python3 scripts/make_dmg.py \
        --app <Spacedown.app> --out Distribution/build/Spacedown-1.0.2.dmg \
        --version 1.0.2 [--icon <AppIcon.icns>]
"""
import argparse
import sys
import tempfile
from pathlib import Path

WIDTH, HEIGHT = 660, 420
APP_POS = (170, 190)
LINK_POS = (490, 190)
ARROW = (176, 180, 194)
TEXT_COLOR = (128, 132, 146)
GRADIENT_TOP = (250, 251, 252)
GRADIENT_BOTTOM = (237, 239, 244)
# 不同 macOS 版本带的中文字体不一样，按顺序取第一个存在的
FONTS = (
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
)


def draw_background(path: Path, scale: int) -> None:
    from PIL import Image, ImageDraw, ImageFont

    width, height = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)

    # 极浅的纵向渐变，比纯白更有层次，也不抢图标
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(round(a + (b - a) * t)
                      for a, b in zip(GRADIENT_TOP, GRADIENT_BOTTOM))
        draw.line([(0, y), (width, y)], fill=color)

    # 中间的箭头：一段横杆 + 圆头箭头，和 App 标记的圆头风格一致
    cx, cy = width // 2, (190 * scale)
    shaft, head, thickness = 30 * scale, 12 * scale, 6 * scale
    draw.line([(cx - shaft - head, cy), (cx + head // 2, cy)],
              fill=ARROW, width=thickness)
    draw.line([(cx - head // 2, cy - head), (cx + head // 2, cy)],
              fill=ARROW, width=thickness)
    draw.line([(cx - head // 2, cy + head), (cx + head // 2, cy)],
              fill=ARROW, width=thickness)

    font = next((ImageFont.truetype(path, 13 * scale)
                 for path in FONTS if Path(path).exists()),
                ImageFont.load_default())
    text = "拖到「应用程序」完成安装"
    text_width = draw.textlength(text, font=font)
    draw.text(((width - text_width) / 2, 330 * scale),
              text, font=font, fill=TEXT_COLOR)

    # ⚠️ DPI 必须写对：1x=72、2x=144。只给像素尺寸的话 tiffutil 会把两张图
    # 当成同一分辨率合并，Finder 会按 2x 尺寸显示背景（箭头被放大、文字被裁掉）。
    image.save(path, dpi=(72 * scale, 72 * scale))


def build(app: Path, out: Path, version: str, icon: Path | None) -> None:
    import dmgbuild

    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        background = tmp / "background.png"
        draw_background(background, scale=1)
        # dmgbuild 会自动找同名 @2x 文件并用 tiffutil 合成 HiDPI 背景
        draw_background(tmp / "background@2x.png", scale=2)

        settings = {
            "volume_name": f"Spacedown {version}",
            "window_rect": ((240, 240), (WIDTH, HEIGHT)),
            "icon_size": 128,
            "text_size": 13,
            "icon_locations": {
                "Spacedown.app": APP_POS,
                "Applications": LINK_POS,
            },
            "background": str(background),
            "files": [str(app)],
            "symlinks": {"Applications": "/Applications"},
            "format": "UDZO",
            "filesystem": "HFS+",
            "hide": [".background", ".VolumeIcon.icns", ".DS_Store"],
        }
        if icon and icon.exists():
            settings["icon"] = str(icon)

        dmgbuild.build_dmg(str(out), settings["volume_name"], settings=settings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--icon", type=Path)
    args = parser.parse_args()

    if not args.app.exists():
        print(f"找不到 App：{args.app}", file=sys.stderr)
        return 1

    try:
        build(args.app, args.out, args.version, args.icon)
    except ImportError:
        print("缺少依赖：pip install dmgbuild pillow", file=sys.stderr)
        return 2

    size = args.out.stat().st_size / 1024 / 1024
    print(f"wrote {args.out} ({size:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
