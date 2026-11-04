#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Draw docs/media/social-preview.png (1280 x 640), the repository's social preview image.

Layout (docs/media/README.md): the 800 x 384 dash snapshot (demo data, placeholder tiles) in a TFT
bezel on the left; the app icon, the name, a one-line pitch, model chips and the licence on the
right. Colours are the app's Theme. Everything important stays 40 px inside the edges, so LinkedIn's
1.91:1 crop (about 1222 x 640, centred) keeps it.

Needs Pillow and the Inter typeface (OFL; Debian/Ubuntu package fonts-inter). Only images from this
repository are used: no logos, no photos, no real map data.

usage: python3 docs/media/make_social_preview.py [--fonts DIR] [--out PATH]
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DASH = os.path.join(ROOT, "docs", "screenshots", "readme", "dash-navigation.png")
ICON = os.path.join(ROOT, "App", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
OUT = os.path.join(ROOT, "docs", "media", "social-preview.png")

W, H = 1280, 640
BACKGROUND_TOP, BACKGROUND_BOTTOM = (0x0E, 0x11, 0x16), (0x17, 0x1B, 0x22)  # Theme.background → surface
BEZEL_FILL, BEZEL_STROKE = (0x05, 0x07, 0x0A), (0x2C, 0x33, 0x3F)
TEXT, TEXT_SUB, TEXT_DIM = (0xF2, 0xF5, 0xFA), (0xC9, 0xD1, 0xD9), (0x9A, 0xA4, 0xB2)
BRAND, CHIP_FILL = (0xFF, 0x6A, 0x2C), (0x1F, 0x24, 0x2E)

BEZEL = (40, 139, 40 + 728, 139 + 362)  # 728 x 362, vertically centred
SCREEN = (52, 151, 52 + 704, 151 + 338)  # the dash picture, 704 x 338 (0.88 of 800 x 384)
COLUMN_X, COLUMN_RIGHT = 800, W - 40


def font(fonts, name, size):
    return ImageFont.truetype(os.path.join(fonts, name), size)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def gradient():
    top, bottom = BACKGROUND_TOP, BACKGROUND_BOTTOM
    column = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((W, H))


def bezel(canvas):
    # Soft shadow: 0 12 32 rgba(0, 0, 0, .5).
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    x0, y0, x1, y1 = BEZEL
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + 12, x1, y1 + 12), radius=22, fill=(0, 0, 0, 128))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16)))
    ImageDraw.Draw(canvas).rounded_rectangle(BEZEL, radius=22, fill=BEZEL_FILL, outline=BEZEL_STROKE, width=2)
    sx0, sy0, sx1, sy1 = SCREEN
    dash = Image.open(DASH).convert("RGBA").resize((sx1 - sx0, sy1 - sy0), Image.LANCZOS)
    canvas.paste(dash, (sx0, sy0), rounded_mask(dash.size, 10))


def right_column(canvas, fonts):
    draw = ImageDraw.Draw(canvas)
    column = COLUMN_RIGHT - COLUMN_X
    icon = Image.open(ICON).convert("RGBA").resize((112, 112), Image.LANCZOS)
    canvas.paste(icon, (COLUMN_X, 72), rounded_mask(icon.size, 25))
    draw.rounded_rectangle((COLUMN_X, 72, COLUMN_X + 111, 72 + 111), radius=25, outline=BEZEL_STROKE, width=1)

    title = font(fonts, "InterDisplay-Bold.otf", 56)
    draw.text((COLUMN_X - 2, 260), "OpenCfMoto", font=title, fill=TEXT, anchor="ls")
    draw.text((COLUMN_X - 2, 324), "for iOS", font=title, fill=BRAND, anchor="ls")

    lines = ["Navigation on CFMOTO MotoPlay", "dashes — from your iPhone"]
    size = 28
    while True:  # both lines must fit the column; shrink the type if they do not
        subtitle = font(fonts, "Inter-Medium.otf", size)
        if max(draw.textlength(s, font=subtitle) for s in lines) <= column or size <= 20:
            break
        size -= 1
    draw.text((COLUMN_X, 380), lines[0], font=subtitle, fill=TEXT_SUB, anchor="ls")
    draw.text((COLUMN_X, 418), lines[1], font=subtitle, fill=TEXT_SUB, anchor="ls")

    models = ["450MT", "800MT", "450SR", "675SR-R"]
    size, pad, gap = 22, 12, 9
    while True:  # the chips must fit the column too
        chip = font(fonts, "Inter-SemiBold.otf", size)
        widths = [draw.textlength(m, font=chip) + 2 * pad for m in models]
        if sum(widths) + gap * (len(models) - 1) <= column or size <= 16:
            break
        size -= 1
    x, top, height = COLUMN_X, 448, 40
    for model, width in zip(models, widths):
        draw.rounded_rectangle((x, top, x + width, top + height), radius=height // 2, fill=CHIP_FILL)
        draw.text((x + width / 2, top + height / 2), model, font=chip, fill=BRAND, anchor="mm")
        x += width + gap

    footer = font(fonts, "Inter-Medium.otf", 20)
    draw.text((COLUMN_X, 548), "Open source · AGPL-3.0 · Swift / SwiftUI", font=footer, fill=TEXT_DIM, anchor="ls")
    widest = max(draw.textlength(s, font=subtitle) for s in lines)
    return max(x - gap, COLUMN_X + widest)  # right edge of the column's content, for the check below


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fonts", default="/usr/share/fonts/opentype/inter", help="folder with the Inter .otf files")
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    canvas = gradient().convert("RGBA")
    bezel(canvas)
    content_right = right_column(canvas, args.fonts)
    if content_right > COLUMN_RIGHT:
        sys.exit("the text does not fit the right column (40 px safe margin)")
    canvas.convert("RGB").save(args.out, "PNG", optimize=True)
    size = os.path.getsize(args.out)
    print(f"{os.path.relpath(args.out, ROOT)}: {W} x {H}, {size // 1024} KB")
    if size >= 1024 * 1024:
        sys.exit("over 1 MB: GitHub refuses social previews of 1 MB or more")


if __name__ == "__main__":
    main()
