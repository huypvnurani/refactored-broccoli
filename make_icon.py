#!/usr/bin/env python3
"""Generate Mac Charge app icon.

Priority:
  1. If ./logo.png (or ./logo.jpg) exists, use that artwork (rounded + resized).
  2. Otherwise procedurally recreate the battery/bolt/arc logo with Pillow.
Outputs Resources/AppIcon.icns via `iconutil`.
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(ROOT, "Resources")
os.makedirs(RES, exist_ok=True)
S = 1024  # master size


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def vgrad(size, top, bottom):
    """Vertical linear gradient image."""
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((size, size))


def arc(draw, box, start, end, width, color):
    draw.arc(box, start=start, end=end, fill=color, width=width)


def load_user_logo():
    for name in ("logo.png", "logo.jpg", "logo.jpeg", "logo.webp"):
        p = os.path.join(ROOT, name)
        if os.path.exists(p):
            return p
    return None


def build_from_user(path):
    # Artwork already carries its own rounded silhouette + soft shadow on a
    # transparent canvas, so use it as-is (just normalise to the master size).
    img = Image.open(path).convert("RGBA")
    if img.size != (S, S):
        img = img.resize((S, S), Image.LANCZOS)
    return img


def build_procedural():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # --- Background: dark rounded square with subtle top glow ---
    bg = vgrad(S, (32, 40, 48), (12, 16, 20)).convert("RGBA")
    radius = int(S * 0.225)
    mask = rounded_mask(S, radius)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img, "RGBA")

    cx = S // 2
    # --- Progress arcs around the battery ---
    pad = int(S * 0.16)
    box = [pad, pad, S - pad, S - pad]
    aw = int(S * 0.055)
    # dim full ring
    arc(d, box, 0, 360, aw, (70, 80, 92, 120))
    # green arc top-left sweep
    for i, col in enumerate([(60, 200, 90, 90), (80, 230, 110, 255)]):
        w = aw + (2 - i) * 6
        arc(d, box, 150, 300, w, col)
    # blue arc bottom-right
    arc(d, box, -35, 60, aw, (70, 170, 255, 255))

    # --- Battery body ---
    bw, bh = int(S * 0.34), int(S * 0.46)
    bx0, by0 = cx - bw // 2, int(S * 0.30)
    bx1, by1 = cx + bw // 2, by0 + bh
    br = int(bw * 0.16)
    # cap
    cap_w, cap_h = int(bw * 0.34), int(S * 0.045)
    d.rounded_rectangle([cx - cap_w // 2, by0 - cap_h, cx + cap_w // 2, by0 + br],
                        radius=int(cap_h * 0.5), fill=(150, 160, 170, 255))

    # glass shell
    d.rounded_rectangle([bx0, by0, bx1, by1], radius=br, fill=(30, 42, 52, 235),
                        outline=(120, 200, 235, 255), width=int(S * 0.012))

    # green->yellow fill (lower ~78%)
    inset = int(S * 0.028)
    fx0, fy0, fx1, fy1 = bx0 + inset, by0 + int(bh * 0.30), bx1 - inset, by1 - inset
    fill_h = fy1 - fy0
    grad = vgrad(fill_h, (196, 226, 40), (46, 200, 96)).convert("RGBA").resize((fx1 - fx0, fill_h))
    gm = Image.new("L", (fx1 - fx0, fill_h), 0)
    ImageDraw.Draw(gm).rounded_rectangle([0, 0, fx1 - fx0 - 1, fill_h - 1],
                                         radius=int(br * 0.7), fill=255)
    img.paste(grad, (fx0, fy0), gm)

    # --- Lightning bolt ---
    d2 = ImageDraw.Draw(img, "RGBA")
    bx, by = cx, (fy0 + fy1) // 2
    u = S * 0.012
    bolt = [
        (bx + 3 * u, by - 11 * u), (bx - 6 * u, by + 2 * u), (bx - 0.5 * u, by + 2 * u),
        (bx - 3 * u, by + 11 * u), (bx + 6 * u, by - 2 * u), (bx + 0.5 * u, by - 2 * u),
    ]
    d2.polygon(bolt, fill=(245, 255, 250, 255))

    # --- Gloss highlight on upper glass ---
    gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.rounded_rectangle([bx0 + inset, by0 + inset, bx1 - inset,
                          by0 + int(bh * 0.24)], radius=br, fill=(255, 255, 255, 60))
    gloss = gloss.filter(ImageFilter.GaussianBlur(6))
    img = Image.alpha_composite(img, gloss)

    # re-apply rounded mask to clip arcs to the tile
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(img, (0, 0), mask)
    return clipped


def main():
    user = load_user_logo()
    icon = build_from_user(user) if user else build_procedural()
    src = "user logo.png" if user else "procedural artwork"

    iconset = os.path.join(RES, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [16, 32, 64, 128, 256, 512, 1024]
    for sz in specs:
        icon.resize((sz, sz), Image.LANCZOS).save(os.path.join(iconset, f"icon_{sz}x{sz}.png"))
        # @2x variants
        half = sz // 2
        if half in (16, 32, 64, 128, 256, 512):
            icon.resize((sz, sz), Image.LANCZOS).save(
                os.path.join(iconset, f"icon_{half}x{half}@2x.png"))

    icns = os.path.join(RES, "AppIcon.icns")
    r = subprocess.run(["iconutil", "-c", "icns", "-o", icns, iconset],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("iconutil failed:", r.stderr, file=sys.stderr)
        sys.exit(1)
    icon.save(os.path.join(RES, "AppIcon_preview.png"))
    print(f"✓ AppIcon.icns generated from {src}")


if __name__ == "__main__":
    main()
