#!/usr/bin/env python3
"""Draw Pith's macOS AppIcon into the asset catalog.

The master is a 1024 canvas with an 824 squircle (100 px transparent margin).
The mark is one picture plate: a warm rounded rect, a sun, and a peak, punched
out of a quiet slate gradient so it stays a single silhouette at 16 px.

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
# Draw the master this many times larger, then downsample.
SCALE = 6

SLATE_TOP = np.array([100, 108, 120], dtype=np.float32)     # #646C78
SLATE_BOTTOM = np.array([48, 54, 64], dtype=np.float32)     # #303640
PAPER = (246, 242, 236, 255)                                 # #F6F2EC

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


def slate(px: int) -> Image.Image:
    ys = np.linspace(0, 1, px, dtype=np.float32)[:, None]
    xs = np.linspace(0, 1, px, dtype=np.float32)[None, :]
    tilt = np.clip(ys * 0.82 + xs * 0.18, 0, 1)[..., None]
    rgb = SLATE_TOP * (1 - tilt) + SLATE_BOTTOM * tilt
    sheen = (np.clip(1.05 - ys * 2.8, 0, 1) ** 1.8)[..., None]
    shade = (np.clip((ys - 0.72) / 0.28, 0, 1))[..., None]
    rgb = np.clip(rgb + sheen * 22 - shade * 16, 0, 255).astype(np.uint8)
    return Image.fromarray(rgb, "RGB").convert("RGBA")


def picture_plate(px: int) -> Image.Image:
    """Warm plate with the sun and peak knocked out, so the slate shows through."""
    plate = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    draw = ImageDraw.Draw(plate)
    s = px / CANVAS
    left, top, right, bottom = 252 * s, 322 * s, 772 * s, 702 * s
    draw.rounded_rectangle([left, top, right, bottom], radius=78 * s, fill=PAPER)

    cut = Image.new("L", (px, px), 0)
    cut_draw = ImageDraw.Draw(cut)
    sun = (left + (right - left) * 0.30, top + (bottom - top) * 0.34)
    sun_r = 46 * s
    cut_draw.ellipse([sun[0] - sun_r, sun[1] - sun_r, sun[0] + sun_r, sun[1] + sun_r], fill=255)
    inset = 36 * s
    base_y = bottom - inset
    cut_draw.polygon([
        (left + inset, base_y),
        ((left + right) / 2 + 20 * s, top + (bottom - top) * 0.46),
        (right - inset, base_y),
    ], fill=255)

    arr = np.array(plate)
    arr[..., 3] = np.where(np.array(cut) > 0, 0, arr[..., 3])
    return Image.fromarray(arr, "RGBA")


def master(scale: int = SCALE) -> Image.Image:
    px = CANVAS * scale
    icon = slate(px)
    icon.putalpha(squircle_mask(px, supersample=1))
    icon.alpha_composite(picture_plate(px))
    mask = np.array(squircle_mask(px, supersample=1))
    arr = np.array(icon)
    arr[..., 3] = (arr[..., 3].astype(np.uint16) * mask.astype(np.uint16) // 255).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


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
    # in the transparent margin so Finder does not see a hard square.
    coverage = np.asarray(squircle_mask(size), dtype=np.float32) / 255.0
    alpha = np.clip(alpha * coverage[..., None], 0, 1)
    rgb = np.clip(rgb, 0, 1)
    return Image.fromarray((np.dstack([rgb, alpha[..., 0]]) * 255 + 0.5).astype(np.uint8), "RGBA")


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


def check(images: dict[int, Image.Image]) -> None:
    for pixels, image in images.items():
        arr = np.array(image)
        if arr.shape != (pixels, pixels, 4):
            raise SystemExit(f"{pixels}px image is {arr.shape}")
        alpha = arr[..., 3]
        margin = max(1, round(pixels * (CANVAS - BODY) / CANVAS / 2) - 1)
        border = max(alpha[:margin].max(), alpha[-margin:].max(), alpha[:, :margin].max(), alpha[:, -margin:].max())
        if int(border) != 0:
            raise SystemExit(f"{pixels}px margin is not transparent (alpha {border})")
        if int(alpha[pixels // 2, pixels // 2]) != 255:
            raise SystemExit(f"{pixels}px center is not opaque")
        opaque = float((alpha > 16).mean())
        if not 0.40 <= opaque <= 0.72:
            raise SystemExit(f"{pixels}px opaque coverage {opaque:.3f} is not a squircle")
        ys, xs = np.where(alpha > 16)
        span = max(xs.max() - xs.min(), ys.max() - ys.min()) + 1
        expected = BODY / CANVAS * pixels
        if abs(span - expected) > max(2.5, expected * 0.08):
            raise SystemExit(f"{pixels}px body span {span} != ~{expected:.1f}")


def main() -> None:
    source = master()
    images = {}
    for _, _, _, pixels in SLOTS:
        images[pixels] = resize_rgba(source, pixels)
    check(images)
    write_catalog(images)
    print(f"wrote {ICONSET.relative_to(ROOT)} ({len(SLOTS)} sizes)")


if __name__ == "__main__":
    main()
