"""Draw the app icon (a paper plane on a rounded square) into an .iconset folder for `iconutil`."""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw


def draw(size: int) -> Image.Image:
    scale = 4  # supersample for smooth edges
    s = size * scale
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = int(s * 0.08)
    top, bottom = (37, 99, 235), (14, 165, 233)
    for y in range(pad, s - pad):  # vertical gradient
        t = (y - pad) / (s - 2 * pad)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(pad, y), (s - pad, y)], fill=color)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, s - pad, s - pad], radius=int(s * 0.2), fill=255)
    img.putalpha(mask)
    d = ImageDraw.Draw(img)
    c = s / 2
    plane = [(c - s * 0.26, c + s * 0.02), (c + s * 0.27, c - s * 0.22), (c + s * 0.06, c + s * 0.26), (c - s * 0.02, c + s * 0.08)]
    d.polygon(plane, fill=(255, 255, 255))
    d.polygon([(c - s * 0.02, c + s * 0.08), (c + s * 0.27, c - s * 0.22), (c - s * 0.06, c + s * 0.2)], fill=(219, 234, 254))
    return img.resize((size, size), Image.LANCZOS)


def main(out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        draw(base).save(out / f"icon_{base}x{base}.png")
        draw(base * 2).save(out / f"icon_{base}x{base}@2x.png")


if __name__ == "__main__":
    main(sys.argv[1])
