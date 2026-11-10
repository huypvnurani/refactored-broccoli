#!/usr/bin/env python3
"""Draws the background of the MacCharge installer window (the DMG).

    python3 make_dmg_background.py <out-dir>

Writes dmg-background.png (1x) and dmg-background@2x.png. The layout numbers
below must match dmg_settings.py: the window is WIDTH x HEIGHT points, the app
icon sits at APP_X, the Applications link at APPS_X, both on ICON_Y; the
install note goes under the divider at NOTE_Y.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH, HEIGHT = 660, 480
APP_X, APPS_X, ICON_Y = 170, 490, 205
NOTE_Y = 390
ICON = 128

BG_TOP = (20, 26, 32)
BG_BOTTOM = (11, 14, 17)
GREEN = (63, 208, 126)
BLUE = (79, 168, 255)
TEXT = (243, 245, 247)
MUTED = (139, 150, 162)
SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    try:
        f = ImageFont.truetype(SF, size)
        f.set_variation_by_name(weight)
        return f
    except (OSError, ValueError):
        return ImageFont.load_default(size)


def draw(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    s = lambda v: int(round(v * scale))

    # Vertical gradient, the app's own dark palette.
    img = Image.new("RGB", (w, h))
    px = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        px.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))

    # Soft glows behind the two icons.
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    for x, color in ((APP_X, GREEN), (APPS_X, BLUE)):
        r = s(92)
        g.ellipse([s(x) - r, s(ICON_Y) - r, s(x) + r, s(ICON_Y) + r], fill=color + (46,))
    glow = glow.filter(ImageFilter.GaussianBlur(s(34)))
    img.paste(glow, (0, 0), glow)

    d = ImageDraw.Draw(img)

    # Title and instruction.
    title = font(s(26), "Bold")
    d.text((w / 2, s(46)), "MacCharge", font=title, fill=TEXT, anchor="mm")
    sub = font(s(13.5), "Regular")
    d.text((w / 2, s(76)), "Drag MacCharge onto Applications to install", font=sub, fill=MUTED, anchor="mm")

    # Arrow from the app to Applications: dots fading in, then a solid head.
    start, end = APP_X + ICON / 2 + 22, APPS_X - ICON / 2 - 22
    y = s(ICON_Y)
    dots = 6
    for i in range(dots):
        t = i / (dots - 1)
        x = s(start + (end - 30 - start) * t)
        r = s(3.2 + 1.2 * t)
        a = int(90 + 165 * t)
        d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(int(c * a / 255 + bg * (1 - a / 255))
                                                         for c, bg in zip(GREEN, BG_TOP)))
    tip = s(end)
    d.line([(tip - s(16), y - s(16)), (tip, y), (tip - s(16), y + s(16))],
           fill=GREEN, width=s(5), joint="curve")
    for px_, py_ in ((tip - s(16), y - s(16)), (tip, y), (tip - s(16), y + s(16))):
        r = s(2.5)
        d.ellipse([px_ - r, py_ - r, px_ + r, py_ + r], fill=GREEN)

    # Divider above the README row.
    d.line([(s(60), s(306)), (w - s(60), s(306))], fill=(30, 37, 44), width=max(1, s(1)))
    return img


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    draw(1).save(out / "dmg-background.png")
    draw(2).save(out / "dmg-background@2x.png")
    print(f"✓ DMG background → {out}/dmg-background(.png|@2x.png)")


if __name__ == "__main__":
    main()
