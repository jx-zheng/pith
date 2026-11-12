#!/usr/bin/env python3
"""Draw before/after ring placement from the IconRingGeometry cases.

The ring used to sit on the cell (icon + label + padding). It now sits on the
icon image. Numbers match Tests/PithCoreTests/IconRingGeometryTests.swift.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path("/opt/cursor/artifacts")

# (name, icon (x, y, w, h), cell (x, y, w, h)) in a y-down space, except the
# drag-image cases which are stored y-up and flipped into the panel.
CASES = [
    ("Icon view, short name", (108, 40, 64, 64), (100, 32, 80, 120), False),
    ("Icon view, two-line name", (108, 40, 64, 64), (90, 32, 140, 168), False),
    ("List row, short name", (18, 42, 16, 16), (0, 40, 220, 20), False),
    ("List row, long name", (18, 42, 16, 16), (0, 40, 640, 20), False),
    ("Drag image, short label", (416, 548, 64, 64), (400, 500, 96, 120), True),
    ("Drag image, long label", (396, 508, 64, 64), (380, 460, 160, 180), True),
]


def center(rect):
    x, y, w, h = rect
    return (x + w / 2, y + h / 2)


def flip(rect, ceiling):
    x, y, w, h = rect
    return (x, ceiling - (y + h), w, h)


def load_font(size):
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw_file(draw, box, icon, label):
    x, y, w, h = [int(v) for v in box]
    draw.rounded_rectangle([x, y, x + w, y + h], radius=10, outline=(150, 146, 138), width=2)
    ix, iy, iw, ih = [int(v) for v in icon]
    draw.rounded_rectangle([ix, iy, ix + iw, iy + ih], radius=8, fill=(255, 252, 247), outline=(70, 74, 82), width=2)
    fold = max(6, iw // 5)
    draw.polygon(
        [(ix + iw - fold, iy), (ix + iw, iy + fold), (ix + iw - fold, iy + fold)],
        fill=(220, 214, 204),
    )
    # Label sits in the part of the cell the icon does not cover.
    if ih + 8 < h and iw > 24:
        draw.text((x + 8, iy + ih + 8), label, fill=(40, 36, 32), font=load_font(13))
    elif w > iw + 8:
        draw.text((ix + iw + 8, y + max(0, (h - 14) // 2)), label, fill=(40, 36, 32), font=load_font(13))


def draw_cross(draw, point, color, radius=7):
    x, y = point
    draw.line([(x - radius, y), (x + radius, y)], fill=color, width=2)
    draw.line([(x, y - radius), (x, y + radius)], fill=color, width=2)
    draw.ellipse([x - 3, y - 3, x + 3, y + 3], outline=color, width=2)


def draw_ring(draw, point, radius, color):
    x, y = point
    draw.ellipse([x - radius, y - radius, x + radius, y + radius], outline=color, width=3)


def render(path: Path, use_icon_center: bool):
    font = load_font(16)
    small = load_font(12)
    panel_w, panel_h = 360, 280
    cols = 3
    rows = 2
    header = 64
    image = Image.new("RGB", (cols * panel_w, header + rows * panel_h), (28, 27, 26))
    draw = ImageDraw.Draw(image)
    title = "After — ring centered on the icon image" if use_icon_center else "Before — ring centered on the cell (icon + label + padding)"
    draw.text((16, 16), title, fill=(255, 248, 240), font=font)
    draw.text((16, 40), "Green cross: icon center.    Orange ring + magenta cross: ring center.", fill=(210, 200, 188), font=small)

    for index, (name, icon, cell, yup) in enumerate(CASES):
        col, row = index % cols, index // cols
        left = col * panel_w
        top = header + row * panel_h
        draw.rectangle([left, top, left + panel_w - 8, top + panel_h - 8], fill=(232, 226, 216))
        ceiling = max(cell[1] + cell[3], icon[1] + icon[3])
        icon_d = flip(icon, ceiling) if yup else icon
        cell_d = flip(cell, ceiling) if yup else cell
        pad = 36
        bounds_w = max(cell_d[0] + cell_d[2], icon_d[0] + icon_d[2]) - min(cell_d[0], icon_d[0])
        bounds_h = max(cell_d[1] + cell_d[3], icon_d[1] + icon_d[3]) - min(cell_d[1], icon_d[1])
        scale = min((panel_w - 48) / max(bounds_w, 1), (panel_h - 78) / max(bounds_h, 1))
        origin_x = min(cell_d[0], icon_d[0])
        origin_y = min(cell_d[1], icon_d[1])

        def map_rect(rect):
            x, y, w, h = rect
            return (
                left + pad + (x - origin_x) * scale,
                top + 36 + (y - origin_y) * scale,
                w * scale,
                h * scale,
            )

        def map_point(point):
            x, y = point
            return (left + pad + (x - origin_x) * scale, top + 36 + (y - origin_y) * scale)

        cell_box = map_rect(cell_d)
        icon_box = map_rect(icon_d)
        label = "Quarterly Report.pdf" if "long" in name or "two-line" in name else "Notes.txt"
        draw_file(draw, cell_box, icon_box, label)
        icon_c = map_point(center(icon_d))
        cell_c = map_point(center(cell_d))
        ring_c = icon_c if use_icon_center else cell_c
        radius = max(icon_box[2], icon_box[3]) * 0.72 + 8
        draw_ring(draw, ring_c, radius, (235, 68, 32))
        draw_cross(draw, icon_c, (16, 140, 70))
        draw_cross(draw, ring_c, (180, 40, 150), radius=5)
        dx = center(icon)[0] - center(cell)[0]
        dy = center(icon)[1] - center(cell)[1]
        draw.text((left + 12, top + 8), name, fill=(30, 26, 22), font=small)
        draw.text(
            (left + 12, top + panel_h - 28),
            f"icon−cell = ({dx:.0f}, {dy:.0f}) pt",
            fill=(80, 60, 40),
            font=small,
        )
    image.save(path)
    print(path)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    render(OUT / "ring-before.png", use_icon_center=False)
    render(OUT / "ring-after.png", use_icon_center=True)


if __name__ == "__main__":
    main()
