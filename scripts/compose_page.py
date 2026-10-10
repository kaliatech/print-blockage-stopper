#!/usr/bin/env python3
"""
Compose the page that gets printed: the test image plus a footer with the
printer's name, IP, model, and the time. Never modifies the source image.

Usage:
  compose_page.py OUT --ppd PPD --media Letter (--preset 4 | --image PATH)
                  --name NAME --ip IP [--model MODEL] [--vary-position]

The page is drawn at the resolution in the queue's PPD, on a canvas the size of
the printable area for the media. `lp -o fit-to-page` then prints it at almost
exactly 1:1, so the content lands where it's drawn. Presets are drawn directly
at that resolution. Other images are scaled to the printable width.

The content is centred vertically, or placed at a random height with
--vary-position. A thin horizontal line is printed only by the nozzles that line
up with it, so moving the pattern between prints spreads the work across all of
them.

If the PPD has no printable area for the media, the content and footer are
written without a canvas, and CUPS centres them on the page.
"""

import argparse
import random
import re
from datetime import datetime

from PIL import Image, ImageDraw, ImageFont

import presets

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
# Used when the PPD doesn't give a resolution, or has no printable area for the media
DEFAULT_DPI = 300


def page_geometry(ppd_path, media):
    """Return (width_px, height_px, dpi) of the printable area, or None."""
    try:
        with open(ppd_path, encoding="utf-8", errors="replace") as f:
            ppd = f.read()
    except OSError:
        return None
    area = re.search(r'^\*ImageableArea ' + re.escape(media) + r'(?:/[^:]*)?:\s*"([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)"',
                     ppd, re.M | re.I)
    if not area:
        return None
    llx, lly, urx, ury = map(float, area.groups())
    res = re.search(r'^\*DefaultResolution:\s*(\d+)', ppd, re.M)
    dpi = int(res.group(1)) if res else DEFAULT_DPI
    return round((urx - llx) / 72 * dpi), round((ury - lly) / 72 * dpi), dpi


def footer(width, dpi, name, ip, model):
    """A bar with a light rule and one line of printer info, in points scaled to dpi."""
    pt = dpi / 72
    parts = [name, ip] + ([model] if model else []) + [datetime.now().strftime("%Y-%m-%d %H:%M")]
    info = "  |  ".join(parts)
    try:
        font = ImageFont.truetype(FONT, round(9 * pt))
    except OSError:
        font = ImageFont.load_default()
    left, top, _, bottom = font.getbbox(info)
    text_h = bottom - top
    bar_h = max(round(text_h + 6 * pt), round(14 * pt))
    img = Image.new("RGB", (width, bar_h), (255, 255, 255))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, width - 1, max(1, round(pt)) - 1], fill=(200, 200, 200))
    draw.text((round(6 * pt) - left, (bar_h - text_h) // 2 - top), info, fill=(100, 100, 100), font=font)
    return img


def fit(img, max_w, max_h):
    """Scale img to fit within max_w x max_h, keeping its aspect ratio."""
    scale = min(max_w / img.width, max_h / img.height)
    size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
    return img if size == img.size else img.resize(size, Image.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description="Compose the maintenance print page")
    parser.add_argument("out")
    parser.add_argument("--ppd", required=True)
    parser.add_argument("--media", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--preset", choices=list(presets.PRESETS))
    source.add_argument("--image")
    parser.add_argument("--name", required=True)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--vary-position", action="store_true")
    args = parser.parse_args()

    geometry = page_geometry(args.ppd, args.media)
    dpi = geometry[2] if geometry else DEFAULT_DPI
    if geometry:
        page_w, page_h = geometry[:2]
        content_w = page_w
    elif args.preset:
        content_w = round(presets.WIDTH / 72 * dpi)
    else:
        content_w = None

    if args.preset:
        content = presets.render_preset(args.preset, content_w)
    else:
        content = Image.open(args.image).convert("RGB")
        if content_w:
            content = fit(content, content_w, content.height * content_w / content.width)

    bar = footer(content.width, dpi, args.name, args.ip, args.model)
    if geometry and content.height + bar.height > page_h:
        content = fit(content, page_w, page_h - bar.height)
        bar = footer(content.width, dpi, args.name, args.ip, args.model)

    block = Image.new("RGB", (content.width, content.height + bar.height), (255, 255, 255))
    block.paste(content, (0, 0))
    block.paste(bar, (0, content.height))

    if not geometry:
        block.save(args.out, "PNG", dpi=(dpi, dpi))
        print(f"No printable area for {args.media} in the PPD. Printing the image centred by CUPS.")
        return

    slack = page_h - block.height
    y = random.randint(0, slack) if args.vary_position else slack // 2
    page = Image.new("RGB", (page_w, page_h), (255, 255, 255))
    page.paste(block, ((page_w - block.width) // 2, y))
    page.save(args.out, "PNG", dpi=(dpi, dpi))
    placement = "random height" if args.vary_position else "centred"
    print(f"Page {page_w}x{page_h} px at {dpi} dpi. Content {y / dpi:.2f} in below the top of "
          f"the printable area ({placement}, {slack / dpi:.2f} in of room).")


if __name__ == "__main__":
    main()
