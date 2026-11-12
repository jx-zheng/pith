#!/usr/bin/env python3
"""Draw Pith's macOS AppIcon into the asset catalog.

The master is a 1024 canvas with an 824 squircle (100 px transparent margin).
The mark is Citrus pith: a cream slice with six pointed wedges on a warm
orange squircle, a soft top highlight, a drop shadow, and a hairline edge.

The 16 px and 32 px slots use a simplified four-wedge drawing (bolder
rind, no hairline, no highlight, pixel-aligned membranes) so the slice
stays legible. From 64 px up, including 32@2x, the full six-wedge mark
still reads, so those slots keep it.

Requires Pillow and numpy. Regenerates App/Assets.xcassets in place:

    python3 scripts/make_app_icon.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

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
# Geometry is in output pixels, tuned per size: a 2 px membrane is the
# centered stroke at both 16 and 32, and the 32 px ring is thinner
# relative to the disk so the quadrants stay the larger shapes.
SMALL_PIXELS = frozenset({16, 32})
SMALL_GEOM = {
    16: {"outer": 5.0, "inner": 4.0, "gap": 2.0, "aa": False},
    32: {"outer": 10.5, "inner": 8.5, "gap": 2.0, "aa": True},
}
# Deeper tile than the full mark's highlighted top, and a lighter flesh,
# so the quadrants still separate on a white desktop.
SMALL_BG_TOP = np.array([255, 122, 46], dtype=np.float32)    # #FF7A2E
SMALL_BG_BOTTOM = np.array([232, 74, 20], dtype=np.float32)  # #E84A14
SMALL_CREAM = np.array([255, 252, 246], dtype=np.float32)    # #FFFCF6
SMALL_FLESH = np.array([255, 150, 70], dtype=np.float32)     # #FF9646

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


def small_icon(px: int) -> Image.Image:
    """Four-wedge slice. Membranes are a centered integer-pixel stroke."""
    geom = SMALL_GEOM[px]
    supersample = 8 if geom["aa"] else 1
    big = px * supersample
    center = px / 2.0
    y = (np.arange(big, dtype=np.float32)[:, None] + 0.5) / supersample
    x = (np.arange(big, dtype=np.float32)[None, :] + 0.5) / supersample
    dx = x - center
    dy = y - center
    dist = np.hypot(dx, dy)

    top = (CANVAS - BODY) / 2.0 / CANVAS * px
    t = np.clip((y - top) / (px - 2.0 * top), 0.0, 1.0)
    rgb = np.empty((big, big, 3), dtype=np.float32)
    rgb[:] = _lerp(SMALL_BG_TOP, SMALL_BG_BOTTOM, t)
    rgb[dist <= geom["outer"]] = SMALL_CREAM
    membrane = (np.abs(dx) < geom["gap"] / 2.0) | (np.abs(dy) < geom["gap"] / 2.0)
    rgb[(dist <= geom["inner"]) & ~membrane] = SMALL_FLESH

    if supersample == 1:
        alpha = np.asarray(squircle_mask(px), dtype=np.float32) / 255.0
        out = np.dstack([np.clip(rgb / 255.0, 0, 1), alpha])
        return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")

    mask = np.asarray(squircle_mask(big, supersample=1), dtype=np.float32) / 255.0
    straight = np.dstack([np.clip(rgb / 255.0, 0, 1), mask])
    prem = straight.copy()
    prem[..., :3] *= prem[..., 3:4]
    folded = prem.reshape(px, supersample, px, supersample, 4).mean(axis=(1, 3))
    alpha = folded[..., 3:4]
    out_rgb = np.zeros_like(folded[..., :3])
    np.divide(folded[..., :3], np.maximum(alpha, 1e-6), out=out_rgb, where=alpha > 1e-4)
    out = np.dstack([np.clip(out_rgb, 0, 1), np.clip(alpha[..., 0], 0, 1)])
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


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


def check(images: dict[int, Image.Image]) -> None:
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
            cream = (alpha > 200) & (rgb[..., 1] > 210) & (rgb[..., 2] > 190)
            orange = (alpha > 200) & (rgb[..., 0] > 180) & (rgb[..., 1] < 190) & (rgb[..., 2] < 140)
            if int(cream.sum()) < 4 or int(orange.sum()) < 4:
                raise SystemExit(f"{pixels}px simplified mark is missing cream ({cream.sum()}) or orange ({orange.sum()})")
            # Membranes are centered on an even canvas, so they land on whole pixels.
            flesh = tuple(int(v) for v in SMALL_FLESH)
            pith = tuple(int(v) for v in SMALL_CREAM)
            if pixels == 16:
                solid = {((6, 6), flesh), ((6, 7), pith), ((7, 8), pith)}
            else:
                solid = {((12, 12), flesh), ((12, 15), pith), ((12, 14), flesh)}
            for (y, x), expect in solid:
                got = tuple(int(v) for v in arr[y, x])
                if got != (*expect, 255):
                    raise SystemExit(f"{pixels}px ({x},{y}) is {got}, expected {expect} opaque")
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


def main() -> None:
    body = render_body()
    images: dict[int, Image.Image] = {}
    for _, _, _, pixels in SLOTS:
        if pixels in images:
            continue
        images[pixels] = small_icon(pixels) if pixels in SMALL_PIXELS else full_icon(pixels, body)
    check(images)
    write_catalog(images)
    small = ", ".join(f"{p}px" for p in sorted(SMALL_PIXELS))
    print(f"wrote {ICONSET.relative_to(ROOT)} ({len(SLOTS)} slots; simplified at {small})")


if __name__ == "__main__":
    main()
