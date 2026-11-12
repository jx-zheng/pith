#!/usr/bin/env python3
"""Draw Pith's macOS AppIcon into the asset catalog.

The master is a 1024 canvas with an 824 squircle (100 px transparent margin).
The mark is Citrus pith: a cream slice with six pointed wedges on a warm
orange squircle, a soft top highlight, a drop shadow, and a hairline edge.

The 16 px and 32 px slots use a simplified drawing so the mark still
reads as citrus. `--small-variant` selects it: `a` is three wedges with
dark pixel-aligned membranes, `b` is three filled segments, `c` is a
half-slice. From 64 px up, including 32@2x, the full six-wedge mark
still reads, so those slots keep it. The default variant is `c`.

Requires Pillow and numpy. Regenerates App/Assets.xcassets in place:

    python3 scripts/make_app_icon.py
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS = 1024
BODY = 824
# Superellipse exponent. n=5 meets the diagonal clearance of an ~185 px
# corner on the 824 body, which is the macOS rounded-squircle grid.
SQUIRCLE_N = 5.0
# Draw the full mark this many times larger, then downsample.
SCALE = 4

# Warm orange tile. The sheen is a white wash over the top half only.
BG_TOP = np.array([255, 138, 58], dtype=np.float32)       # #FF8A3A
BG_BOTTOM = np.array([240, 82, 30], dtype=np.float32)     # #F0521E
SHEEN = 0.18

# Cream pith disk and the contact shadow under the slice.
PITH_R = 300.0
PITH_TOP = np.array([255, 252, 246], dtype=np.float32)    # #FFFCF6
PITH_BOTTOM = np.array([247, 235, 220], dtype=np.float32) # #F7EBDC
PITH_SHADOW_DY = 6.0
PITH_SHADOW_BLUR = 10.0
PITH_SHADOW_ALPHA = 0.22

# Six pointed wedges. Angles are degrees clockwise from 12 o'clock.
# A same-color stroke of WEDGE_STROKE expands the fill by half that width
# (round joins), which is what leaves the cream membranes and the rind.
WEDGE_COUNT = 6
WEDGE_OUTER_R = 260.0
WEDGE_GAP = 42.0
WEDGE_TIP_EXTRA = 6.0
WEDGE_STROKE = 16.0
FLESH_TOP = np.array([255, 154, 69], dtype=np.float32)    # #FF9A45
FLESH_BOTTOM = np.array([255, 112, 48], dtype=np.float32) # #FF7030
FLESH_Y0 = 230.0
FLESH_Y1 = 790.0

# Shadow sits in the transparent margin. The hairline is a 2 px white edge.
ICON_SHADOW_DY = 10.0
ICON_SHADOW_BLUR = 12.0
ICON_SHADOW_ALPHA = 0.28
HAIRLINE_WIDTH = 2.0
HAIRLINE_ALPHA = 0.10

# Simplified mark for the slots where six wedges blur together.
# 64 px (32@2x) still shows the full slice, so it is not in this set.
SMALL_PIXELS = frozenset({16, 32})
SMALL_VARIANTS = ("a", "b", "c")
# Half-slice: at 16 px the silhouette itself is a piece of citrus.
DEFAULT_SMALL = "c"
# Deeper tile than the full mark's highlighted top. No sheen, no shadow.
SMALL_BG_TOP = np.array([255, 122, 46], dtype=np.float32)    # #FF7A2E
SMALL_BG_BOTTOM = np.array([208, 60, 14], dtype=np.float32)  # #D03C0E
SMALL_CREAM = np.array([255, 252, 246], dtype=np.float32)    # #FFFCF6
SMALL_PALE = np.array([255, 170, 78], dtype=np.float32)      # #FFAA4E
SMALL_MID = np.array([255, 128, 42], dtype=np.float32)       # #FF802A
SMALL_DEEP = np.array([168, 62, 16], dtype=np.float32)       # #A83E10
SMALL_DARK = np.array([120, 42, 12], dtype=np.float32)       # #782A0C

# macOS app-icon slots. 512@2x is the 1024 master. There is no separate
# iOS marketing image and no Icon Composer bundle.
SLOTS = (
    ("icon_16x16.png", "16x16", "1x", 16),
    ("icon_16x16@2x.png", "16x16", "2x", 32),
    ("icon_32x32.png", "32x32", "1x", 32),
    ("icon_32x32@2x.png", "32x32", "2x", 64),
    ("icon_128x128.png", "128x128", "1x", 128),
    ("icon_128x128@2x.png", "128x128", "2x", 256),
    ("icon_256x256.png", "256x256", "1x", 256),
    ("icon_256x256@2x.png", "256x256", "2x", 512),
    ("icon_512x512.png", "512x512", "1x", 512),
    ("icon_512x512@2x.png", "512x512", "2x", 1024),
)


def superellipse(cx: float, cy: float, radius: float, steps: int) -> list[tuple[float, float]]:
    points = []
    for i in range(steps):
        theta = 2 * math.pi * i / steps
        ct, st = math.cos(theta), math.sin(theta)
        points.append((
            cx + radius * math.copysign(abs(ct) ** (2 / SQUIRCLE_N), ct),
            cy + radius * math.copysign(abs(st) ** (2 / SQUIRCLE_N), st),
        ))
    return points


def squircle_mask(px: int, supersample: int = 8) -> Image.Image:
    """Coverage mask for the 824-on-1024 squircle, antialiased down to px."""
    big = px * supersample
    mask = Image.new("L", (big, big), 0)
    body = BODY / CANVAS * big
    radius = body / 2
    ImageDraw.Draw(mask).polygon(
        superellipse(big / 2, big / 2, radius, max(720, big // 2)),
        fill=255,
    )
    return mask.resize((px, px), Image.Resampling.BOX)


def _lerp(top: np.ndarray, bottom: np.ndarray, t: np.ndarray) -> np.ndarray:
    tt = t[..., None]
    return top * (1.0 - tt) + bottom * tt


def gaussian_blur(image: np.ndarray, sigma: float) -> np.ndarray:
    """Separable Gaussian, truncated at 3 sigma. `sigma` is the std deviation."""
    if sigma < 0.25:
        return image
    radius = max(1, int(math.ceil(sigma * 3.0)))
    x = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-0.5 * (x / np.float32(sigma)) ** 2)
    kernel /= kernel.sum()

    def convolve(src: np.ndarray, axis: int) -> np.ndarray:
        pad = [(0, 0), (0, 0)]
        pad[axis] = (radius, radius)
        padded = np.pad(src, pad, mode="constant")
        windows = np.lib.stride_tricks.sliding_window_view(padded, kernel.size, axis=axis)
        return np.tensordot(windows, kernel, axes=([-1], [0]))

    return convolve(convolve(image, 1), 0)


def shift_y(image: np.ndarray, dy: float) -> np.ndarray:
    """Move `image` down by `dy` pixels (fractional). Empty space stays 0."""
    if abs(dy) < 1e-6:
        return image
    height = image.shape[0]
    src = np.arange(height, dtype=np.float32) - np.float32(dy)
    y0 = np.floor(src).astype(np.int32)
    frac = (src - y0).astype(np.float32)
    y1 = y0 + 1
    valid0 = (y0 >= 0) & (y0 < height)
    valid1 = (y1 >= 0) & (y1 < height)
    y0c = np.clip(y0, 0, height - 1)
    y1c = np.clip(y1, 0, height - 1)
    weight0 = valid0.astype(np.float32) * (1.0 - frac)
    weight1 = valid1.astype(np.float32) * frac
    return image[y0c] * weight0[:, None] + image[y1c] * weight1[:, None]


def _point(radius: float, degrees: float, cx: float, cy: float) -> tuple[float, float]:
    theta = math.radians(degrees - 90.0)
    return (cx + radius * math.cos(theta), cy + radius * math.sin(theta))


def _wedge_centerline(a0: float, a1: float, cx: float, cy: float, scale: float) -> list[tuple[float, float]]:
    """Unstroked wedge. `a0`/`a1` are degrees clockwise from 12 o'clock."""
    outer = WEDGE_OUTER_R * scale
    gap = WEDGE_GAP * scale
    extra = WEDGE_TIP_EXTRA * scale
    half = math.radians((a1 - a0) / 2.0)
    tip_r = (gap / 2.0) / math.sin(half) + extra
    inset = math.degrees((gap / 2.0) / outer)
    steps = 96
    points = [
        _point(outer, (a0 + inset) + ((a1 - inset) - (a0 + inset)) * i / steps, cx, cy)
        for i in range(steps + 1)
    ]
    points.append(_point(tip_r, (a0 + a1) / 2.0, cx, cy))
    return points


def _round_offset(points: list[tuple[float, float]], distance: float) -> list[tuple[float, float]]:
    """Outward round-join offset of a wedge polygon by `distance` pixels."""
    count = len(points)
    normals: list[tuple[float, float]] = []
    for i in range(count):
        x0, y0 = points[i]
        x1, y1 = points[(i + 1) % count]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1.0
        normals.append((dy / length, -dx / length))
    offset: list[tuple[float, float]] = []
    for i in range(count):
        n0, n1 = normals[i - 1], normals[i]
        vx, vy = points[i]
        a0 = math.atan2(n0[1], n0[0])
        a1 = math.atan2(n1[1], n1[0])
        sweep = (a1 - a0) % (2 * math.pi)
        if sweep > math.pi:
            sweep -= 2 * math.pi
        steps = max(1, int(round(abs(sweep) / (math.pi / 12))))
        for step in range(steps + 1):
            angle = a0 + sweep * step / steps
            offset.append((vx + distance * math.cos(angle), vy + distance * math.sin(angle)))
    return offset


def wedge_mask(px: int, scale: float) -> np.ndarray:
    mask = Image.new("L", (px, px), 0)
    draw = ImageDraw.Draw(mask)
    cx = cy = px / 2.0
    stroke = (WEDGE_STROKE / 2.0) * scale
    for i in range(WEDGE_COUNT):
        a0 = i * (360.0 / WEDGE_COUNT)
        polygon = _round_offset(_wedge_centerline(a0, a0 + 360.0 / WEDGE_COUNT, cx, cy, scale), stroke)
        draw.polygon(polygon, fill=255)
    return np.asarray(mask) > 127


def _pith_shadow(px: int) -> np.ndarray:
    """Soft contact shadow of the cream disk, in 0..1 alpha at `px` (a multiple of the 1024 grid)."""
    base = CANVAS
    y, x = np.ogrid[:base, :base]
    disk = ((x + 0.5 - base / 2.0) ** 2 + (y + 0.5 - base / 2.0) ** 2) <= PITH_R ** 2
    blurred = gaussian_blur(disk.astype(np.float32), PITH_SHADOW_BLUR)
    alpha = shift_y(blurred, PITH_SHADOW_DY) * PITH_SHADOW_ALPHA
    if px == base:
        return alpha
    return np.asarray(
        Image.fromarray(alpha, mode="F").resize((px, px), Image.Resampling.BILINEAR),
        dtype=np.float32,
    )


def render_body(scale: int = SCALE) -> Image.Image:
    """Full mark inside the squircle, with no margin shadow and no hairline."""
    px = CANVAS * scale
    top = (CANVAS - BODY) / 2.0 * scale
    bottom = top + BODY * scale
    rows = np.arange(px, dtype=np.float32)
    t = (rows - top) / (bottom - top)
    sheen = np.clip(1.0 - t / 0.5, 0.0, 1.0) * SHEEN
    # (px, 1, 3) so the gradient runs top-to-bottom, not across columns.
    wash = (_lerp(BG_TOP, BG_BOTTOM, t) * (1.0 - sheen)[:, None] + 255.0 * sheen[:, None])[:, None, :]
    rgb = np.empty((px, px, 3), dtype=np.float32)
    rgb[:] = wash

    shadow = np.clip(_pith_shadow(px), 0.0, 1.0)
    rgb *= (1.0 - shadow)[..., None]

    cy = px / 2.0
    radius = PITH_R * scale
    y, x = np.ogrid[:px, :px]
    cream = (x + 0.5 - cy) ** 2 + (y + 0.5 - cy) ** 2 <= radius ** 2
    ct = np.clip((rows - (cy - radius)) / (2.0 * radius), 0.0, 1.0)
    pith = _lerp(PITH_TOP, PITH_BOTTOM, ct)
    ys, xs = np.nonzero(cream)
    rgb[ys, xs] = pith[ys]

    wedges = wedge_mask(px, scale)
    ft = np.clip((rows - FLESH_Y0 * scale) / ((FLESH_Y1 - FLESH_Y0) * scale), 0.0, 1.0)
    flesh = _lerp(FLESH_TOP, FLESH_BOTTOM, ft)
    ys, xs = np.nonzero(wedges)
    rgb[ys, xs] = flesh[ys]

    alpha = np.asarray(squircle_mask(px, supersample=1))
    rgba = np.dstack([np.clip(rgb + 0.5, 0, 255).astype(np.uint8), alpha])
    return Image.fromarray(rgba, "RGBA")


def resize_rgba(im: Image.Image, size: int) -> Image.Image:
    channels = np.asarray(im).astype(np.float32) / 255.0
    prem = np.dstack([channels[..., :3] * channels[..., 3:4], channels[..., 3]])
    planes = []
    for i in range(4):
        plane = Image.fromarray(prem[..., i].astype(np.float32), mode="F")
        planes.append(np.asarray(plane.resize((size, size), Image.Resampling.LANCZOS), dtype=np.float32))
    stacked = np.stack(planes, axis=-1)
    alpha = stacked[..., 3:4]
    rgb = np.zeros_like(stacked[..., :3])
    np.divide(stacked[..., :3], np.maximum(alpha, 1e-6), out=rgb, where=alpha > 1e-4)
    # Lanczos rings past the squircle. The native mask puts that fringe back
    # in the transparent margin so the drop shadow can occupy it cleanly.
    coverage = np.asarray(squircle_mask(size), dtype=np.float32) / 255.0
    alpha = np.clip(alpha * coverage[..., None], 0, 1)
    rgb = np.clip(rgb, 0, 1)
    return Image.fromarray((np.dstack([rgb, alpha[..., 0]]) * 255 + 0.5).astype(np.uint8), "RGBA")


def _straight(rgb: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    return np.dstack([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)])


def composite(dst: np.ndarray, src: np.ndarray) -> np.ndarray:
    """Source-over of straight-alpha float images."""
    src_a = src[..., 3:4]
    dst_a = dst[..., 3:4]
    out_a = src_a + dst_a * (1.0 - src_a)
    out_rgb = src[..., :3] * src_a + dst[..., :3] * dst_a * (1.0 - src_a)
    np.divide(out_rgb, np.maximum(out_a, 1e-6), out=out_rgb, where=out_a > 1e-6)
    return _straight(out_rgb, out_a[..., 0])


def outer_shadow(size: int) -> np.ndarray:
    mask = np.asarray(squircle_mask(size), dtype=np.float32) / 255.0
    sigma = ICON_SHADOW_BLUR * size / CANVAS
    blurred = gaussian_blur(mask, sigma)
    alpha = shift_y(blurred, ICON_SHADOW_DY * size / CANVAS) * ICON_SHADOW_ALPHA
    return _straight(np.zeros((size, size, 3), dtype=np.float32), alpha)


def hairline(size: int) -> np.ndarray:
    supersample = 4
    big = size * supersample
    stroke = max(1, int(round(HAIRLINE_WIDTH * supersample * size / CANVAS)))
    mask = Image.new("L", (big, big), 0)
    radius = (BODY / CANVAS) * big / 2.0
    points = superellipse(big / 2.0, big / 2.0, radius, max(720, big // 2))
    ImageDraw.Draw(mask).line(points + [points[0]], fill=255, width=stroke, joint="curve")
    coverage = np.asarray(mask, dtype=np.float32).reshape(size, supersample, size, supersample).mean(axis=(1, 3))
    alpha = coverage / 255.0 * HAIRLINE_ALPHA
    white = np.ones((size, size, 3), dtype=np.float32)
    return _straight(white, alpha)


def full_icon(size: int, body: Image.Image) -> Image.Image:
    scaled = np.asarray(resize_rgba(body, size)).astype(np.float32) / 255.0
    image = composite(composite(outer_shadow(size), scaled), hairline(size))
    return Image.fromarray((np.clip(image, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGBA")


def _pixel_grid(px: int) -> tuple[np.ndarray, np.ndarray]:
    """Pixel-center coordinates. Hard tests on these snap fills to whole pixels."""
    y = np.arange(px, dtype=np.float32)[:, None] + 0.5
    x = np.arange(px, dtype=np.float32)[None, :] + 0.5
    return x, y


def _small_canvas(px: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    x, y = _pixel_grid(px)
    top = (CANVAS - BODY) / 2.0 / CANVAS * px
    t = np.clip((y - top) / max(px - 2.0 * top, 1e-6), 0.0, 1.0)
    rgb = np.empty((px, px, 3), dtype=np.float32)
    rgb[:] = _lerp(SMALL_BG_TOP, SMALL_BG_BOTTOM, t)
    return rgb, x, y


def _finish_small(rgb: np.ndarray) -> Image.Image:
    alpha = np.asarray(squircle_mask(rgb.shape[0]), dtype=np.float32) / 255.0
    out = np.dstack([np.clip(rgb / 255.0, 0.0, 1.0), alpha])
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


def _angle_up(dx: np.ndarray, dy: np.ndarray) -> np.ndarray:
    """Degrees clockwise from 12 o'clock."""
    return (np.degrees(np.arctan2(dx, -dy)) + 360.0) % 360.0


def _in_cw(angle: np.ndarray, start: float, end: float) -> np.ndarray:
    angle = np.mod(angle, 360.0)
    start %= 360.0
    end %= 360.0
    if start <= end:
        return (angle >= start) & (angle < end)
    return (angle >= start) | (angle < end)


def _membrane(dx, dy, dist, inner, angles, half) -> np.ndarray:
    mask = np.zeros(dist.shape, dtype=bool)
    for degrees in angles:
        theta = math.radians(degrees)
        ux, uy = math.sin(theta), -math.cos(theta)
        perp = np.abs(dx * uy - dy * ux)
        along = dx * ux + dy * uy
        mask |= (perp <= half) & (along >= -0.2) & (dist <= inner + 0.15)
    return mask


def _mark_center(px: int, width: int) -> float:
    """1 px strokes sit on a pixel. 2 px strokes sit on the boundary between pixels."""
    return px / 2.0 - 0.5 if width == 1 else px / 2.0


def small_cross(px: int) -> Image.Image:
    """The rejected four-wedge cross, kept for the comparison sheet."""
    rgb, x, y = _small_canvas(px)
    scale = px / 16.0
    center = px / 2.0
    dist = np.hypot(x - center, y - center)
    outer, inner, gap = 5.0 * scale, 4.0 * scale, 2.0 * scale
    rgb[dist <= outer] = SMALL_CREAM
    membrane = (np.abs(x - center) < gap / 2.0) | (np.abs(y - center) < gap / 2.0)
    rgb[(dist <= inner) & ~membrane] = SMALL_MID
    return _finish_small(rgb)


def small_a(px: int) -> Image.Image:
    """Three wedges in a Y, divided by dark pixel-aligned membranes.

    Cream spokes at this size read as a peace sign. A 1 px (16) or 2 px (32)
    dark line keeps the three wedges as the figure, inside the cream rind.
    One wedge points up, so the division is not a plus.
    """
    rgb, x, y = _small_canvas(px)
    scale = px / 16.0
    width = 1 if px <= 16 else 2
    center = _mark_center(px, width)
    dx, dy = x - center, y - center
    dist = np.hypot(dx, dy)
    outer = 5.55 * scale
    inner = outer - 1.45 * scale
    rgb[dist <= outer] = SMALL_CREAM
    angle = _angle_up(dx, dy)
    for index, color in enumerate((SMALL_PALE, SMALL_MID, SMALL_DEEP)):
        mid = index * 120.0
        delta = (angle - mid + 180.0) % 360.0 - 180.0
        rgb[(np.abs(delta) <= 58.0) & (dist <= inner)] = color
    rgb[_membrane(dx, dy, dist, inner, (60.0, 180.0, 300.0), width / 2.0)] = SMALL_DARK
    return _finish_small(rgb)


def small_b(px: int) -> Image.Image:
    """Three filled segments. Cream rind, hub, and gaps; the pulp is the figure.

    Each segment is its own orange, so the mark reads as pieces of fruit
    rather than as spokes.
    """
    rgb, x, y = _small_canvas(px)
    scale = px / 16.0
    center = px / 2.0
    dx, dy = x - center, y - center
    dist = np.hypot(dx, dy)
    angle = _angle_up(dx, dy)
    outer = 5.6 * scale
    inner = outer - 1.4 * scale
    hub = 1.15 * scale
    rgb[dist <= outer] = SMALL_CREAM
    half = (120.0 - 22.0) / 2.0
    for index, color in enumerate((SMALL_PALE, SMALL_MID, SMALL_DEEP)):
        mid = index * 120.0
        delta = (angle - mid + 180.0) % 360.0 - 180.0
        rgb[(np.abs(delta) <= half) & (dist <= inner) & (dist >= hub)] = color
    return _finish_small(rgb)


def small_c(px: int) -> Image.Image:
    """Half-slice. Semicircle, cream rind and cut, three wedge segments."""
    rgb, x, y = _small_canvas(px)
    scale = px / 16.0
    radius = 6.4 * scale
    cx = px / 2.0
    cy = px / 2.0 + radius * 0.42
    dx, dy = x - cx, y - cy
    dist = np.hypot(dx, dy)
    body = (dist <= radius) & (dy <= 0.25)
    rind = 1.35 * scale
    angle = _angle_up(dx, dy)
    pulp = body & (dist < radius - rind) & (dy < -0.5 * scale)
    for start, end, color in ((270.0, 330.0, SMALL_DEEP), (330.0, 30.0, SMALL_MID), (30.0, 90.0, SMALL_PALE)):
        rgb[pulp & _in_cw(angle, start, end)] = color
    half = 0.45 if px <= 16 else 0.9
    for degrees in (330.0, 30.0):
        theta = math.radians(degrees)
        ux, uy = math.sin(theta), -math.cos(theta)
        perp = np.abs(dx * uy - dy * ux)
        along = dx * ux + dy * uy
        rgb[(perp <= half) & (along > 0.3 * scale) & (dy < -0.55 * scale) & (dist < radius - rind)] = SMALL_CREAM
    rgb[body & (dist >= radius - rind)] = SMALL_CREAM
    cut = 0.5 if px <= 16 else 0.65 * scale
    rgb[(np.abs(dy) <= cut) & (np.abs(dx) <= radius - 0.35 * scale)] = SMALL_CREAM
    return _finish_small(rgb)


def small_icon(px: int, variant: str = DEFAULT_SMALL) -> Image.Image:
    return {"a": small_a, "b": small_b, "c": small_c}[variant](px)


def write_catalog(images: dict[int, Image.Image]) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    catalog = ICONSET.parent
    (catalog / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    slots = []
    for filename, size, scale, pixels in SLOTS:
        images[pixels].save(ICONSET / filename, format="PNG", optimize=True)
        slots.append({
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": size,
        })
    (ICONSET / "Contents.json").write_text(
        json.dumps({"images": slots, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def _border_max(alpha: np.ndarray, band: int) -> int:
    return int(max(
        alpha[:band].max(),
        alpha[-band:].max(),
        alpha[:, :band].max(),
        alpha[:, -band:].max(),
    ))


def check(images: dict[int, Image.Image], variant: str) -> None:
    for pixels, image in images.items():
        arr = np.asarray(image)
        if arr.shape != (pixels, pixels, 4):
            raise SystemExit(f"{pixels}px image is {arr.shape}")
        alpha = arr[..., 3]
        rgb = arr[..., :3]
        if int(alpha[pixels // 2, pixels // 2]) < 250:
            raise SystemExit(f"{pixels}px center is not opaque")
        if pixels in SMALL_PIXELS:
            # No drop shadow, so the margin outside the squircle stays clear.
            margin = max(1, round(pixels * (CANVAS - BODY) / CANVAS / 2) - 1)
            border = _border_max(alpha, margin)
            if border != 0:
                raise SystemExit(f"{pixels}px margin is not transparent (alpha {border})")
            cream = (alpha > 200) & (rgb[..., 1] > 220) & (rgb[..., 2] > 190)
            # Pulp or tile orange. Deep pulp is darker than 180 red, so count that too.
            orange = (alpha > 200) & (rgb[..., 0] > 140) & (rgb[..., 1] < 200) & (rgb[..., 2] < 120)
            if int(cream.sum()) < 8 or int(orange.sum()) < 8:
                raise SystemExit(f"{pixels}px {variant} mark is missing cream ({cream.sum()}) or orange ({orange.sum()})")
            # A plus is a cream row and a cream column crossing at the center.
            mid = pixels // 2
            row = cream[mid]
            col = cream[:, mid]
            if int(row.sum()) > pixels * 0.45 and int(col.sum()) > pixels * 0.45:
                raise SystemExit(f"{pixels}px {variant} mark still reads as a cream cross")
        else:
            # Shadow dies inside the margin. The outer ~48 px of the 1024 canvas stays clear.
            band = max(1, round(pixels * 48 / CANVAS))
            border = _border_max(alpha, band)
            if border != 0:
                raise SystemExit(f"{pixels}px outer margin is not transparent (alpha {border})")
        body = alpha > 200
        coverage = float(body.mean())
        if not 0.45 <= coverage <= 0.75:
            raise SystemExit(f"{pixels}px opaque coverage {coverage:.3f} is not a squircle")
        ys, xs = np.nonzero(body)
        span = max(int(xs.max() - xs.min()), int(ys.max() - ys.min())) + 1
        expected = BODY / CANVAS * pixels
        if abs(span - expected) > max(2.5, expected * 0.08):
            raise SystemExit(f"{pixels}px body span {span} != ~{expected:.1f}")

    master = np.asarray(images[1024])
    center = master[512, 512, :3].astype(int)
    if abs(int(center[0]) - 251) > 8 or abs(int(center[1]) - 243) > 8:
        raise SystemExit(f"1024 center {tuple(int(v) for v in center)} is not the cream pith")
    # 30° wedge, r=150: flesh, not cream. 0° gap, r=200: cream membrane.
    wedge = master[382, 587, :3].astype(int)
    gap = master[312, 512, :3].astype(int)
    if int(wedge[1]) > 180:
        raise SystemExit(f"1024 wedge {tuple(int(v) for v in wedge)} is not flesh")
    if int(gap[1]) < 220:
        raise SystemExit(f"1024 membrane {tuple(int(v) for v in gap)} is not cream")
    if int(master[936, 512, 3]) < 8:
        raise SystemExit("1024 drop shadow is missing under the squircle")


def export_options(body: Image.Image, dest: Path) -> None:
    """Write every small-size option, plus a light/dark comparison sheet."""
    if not dest.is_absolute():
        dest = ROOT / dest
    dest.mkdir(parents=True, exist_ok=True)
    drawings = {
        "current": small_cross,
        "a": small_a,
        "b": small_b,
        "c": small_c,
    }
    full = full_icon(512, body)
    for name, draw in drawings.items():
        if name == "current":
            continue
        icon16 = draw(16)
        icon32 = draw(32)
        icon16.save(dest / f"{name}-16.png", format="PNG", optimize=True)
        icon32.save(dest / f"{name}-32.png", format="PNG", optimize=True)
        # 16@2x and 32@1x are both the 32 px slot.
        icon32.save(dest / f"{name}-16@2x.png", format="PNG", optimize=True)
        icon32.save(dest / f"{name}-32@1x.png", format="PNG", optimize=True)

    labels = (
        ("current", "Current  4 wedges"),
        ("a", "A  3 wedges"),
        ("b", "B  filled segments"),
        ("c", "C  half slice"),
    )
    bold = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 28)
    caption = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 20)

    def panel(background: tuple[int, int, int], ink: tuple[int, int, int]) -> Image.Image:
        label_w, gap, margin = 280, 28, 28
        row_h = 512 + 52
        width = margin * 2 + label_w + 512 + gap + 16 + gap + 32 + gap + 128 + gap + 128
        height = margin + len(labels) * row_h
        image = Image.new("RGBA", (width, height), background + (255,))
        draw = ImageDraw.Draw(image)
        names = ("512", "16", "32", "16 ×8", "32 ×4")
        for index, (key, title) in enumerate(labels):
            y = margin + index * row_h
            draw.text((margin, y + 8), title, fill=ink + (255,), font=bold)
            x = margin + label_w
            image.alpha_composite(full, (x, y))
            draw.text((x, y + 518), names[0], fill=ink + (255,), font=caption)
            x += 512 + gap
            mark = drawings[key]
            for name, (pixels, zoom) in zip(names[1:], ((16, 1), (32, 1), (16, 8), (32, 4))):
                icon = mark(pixels)
                shown = icon.resize((pixels * zoom, pixels * zoom), Image.Resampling.NEAREST) if zoom != 1 else icon
                image.alpha_composite(shown, (x, y + 512 - shown.height))
                draw.text((x, y + 518), name, fill=ink + (255,), font=caption)
                x += shown.width + gap
        return image

    light = panel((242, 242, 246), (28, 28, 32))
    dark = panel((28, 28, 32), (236, 236, 240))
    sheet = Image.new("RGB", (light.width, light.height + dark.height + 56), (255, 255, 255))
    banner = ImageDraw.Draw(sheet)
    sheet.paste(light.convert("RGB"), (0, 28))
    banner.text((28, 2), "Light", fill=(28, 28, 32), font=bold)
    sheet.paste(dark.convert("RGB"), (0, light.height + 56))
    banner.text((28, light.height + 30), "Dark", fill=(28, 28, 32), font=bold)
    sheet.save(dest / "sheet.png", format="PNG", optimize=True)
    print(f"wrote {dest}")


def build_images(body: Image.Image, variant: str) -> dict[int, Image.Image]:
    images: dict[int, Image.Image] = {}
    for _, _, _, pixels in SLOTS:
        if pixels in images:
            continue
        images[pixels] = small_icon(pixels, variant) if pixels in SMALL_PIXELS else full_icon(pixels, body)
    return images


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Draw Pith's macOS AppIcon.")
    parser.add_argument("--small-variant", choices=SMALL_VARIANTS, default=DEFAULT_SMALL,
                        help="small-size drawing for the 16 px and 32 px slots (default: c)")
    parser.add_argument("--export-options", type=Path, default=None,
                        help="also write design/small-icon-options (every variant and the sheet)")
    args = parser.parse_args(argv)
    body = render_body()
    if args.export_options is not None:
        export_options(body, args.export_options)
    images = build_images(body, args.small_variant)
    check(images, args.small_variant)
    write_catalog(images)
    small = ", ".join(f"{p}px" for p in sorted(SMALL_PIXELS))
    print(f"wrote {ICONSET.relative_to(ROOT)} ({len(SLOTS)} slots; {args.small_variant} at {small})")


if __name__ == "__main__":
    main()
