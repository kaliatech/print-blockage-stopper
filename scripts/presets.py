#!/usr/bin/env python3
"""
Generate ink-efficient maintenance test images for common ink configurations.

Design goals (inspired by Qimage One purge patterns):
  1. Exercise EVERY ink channel — pure colour patches + nozzle check lines
  2. Include blends between adjacent channels to fire nozzle combinations
  3. Use fine staggered lines (nozzle check style) not solid blocks
  4. Keep total ink coverage low — ~10-15% of page vs 40%+ for solid swatches
  5. Distribute colours so no single channel fires continuously

Layout per preset:
  ┌─────────────────────────────────────┐
  │ Title                               │
  ├─────────────────────────────────────┤
  │ NOZZLE CHECK LINES (staggered)      │
  │  Thin horizontal lines per channel  │
  ├─────────────────────────────────────┤
  │ COLOUR PATCHES (small, staggered)   │
  │  Pure + light shade per channel     │
  ├─────────────────────────────────────┤
  │ BLEND STRIPS                        │
  │  Gradients between adjacent inks    │
  ├─────────────────────────────────────┤
  │ Footer                              │
  └─────────────────────────────────────┘

Presets:
  4-colour:  CMYK
  6-colour:  CMYK + Light Cyan + Light Magenta
  8-colour:  CMYK + LC + LM + Light Black + Light Light Black
  11-colour: CMYK + LC + LM + LK + LLK + Red + Blue + Matte Black
  12-colour: CMYK + LC + LM + LK + LLK + Red + Blue + Green + Matte Black

The layout is in units of about one point. Its 600-unit width fills the
printable width (8.27 in on Letter, so one unit is 0.99 pt there).
render_preset() draws it at any pixel width. compose_page.py calls it at the
printer's resolution, so lines and text are drawn at full resolution instead of
being scaled up. Running this file writes 300 dpi PNGs for the dashboard's
thumbnails and download links.

Usage: presets.py [OUTPUT_DIR]
"""

from PIL import Image, ImageDraw, ImageFont
import os
import sys

# Layout size in units
WIDTH = 600
MARGIN = 14
# Resolution of the PNGs written by main()
PNG_DPI = 300
FONT_DIR = "/usr/share/fonts/truetype/dejavu"

# Ink channel colours (RGB approximations that force specific ink channels)
CHANNELS = {
    "Cyan":           (0, 174, 239),
    "Magenta":        (236, 0, 140),
    "Yellow":         (255, 242, 0),
    "Black":          (35, 31, 32),
    "Light Cyan":     (119, 210, 243),
    "Light Magenta":  (237, 140, 196),
    "Light Black":    (128, 128, 128),
    "Light Lt Black": (190, 190, 190),
    "Red":            (237, 28, 36),
    "Blue":           (0, 68, 181),
    "Green":          (0, 148, 68),
    "Matte Black":    (60, 55, 50),
}

ABBREVS = {
    "Cyan": "C", "Magenta": "M", "Yellow": "Y", "Black": "K",
    "Light Cyan": "LC", "Light Magenta": "LM",
    "Light Black": "LK", "Light Lt Black": "LLK",
    "Red": "R", "Blue": "B", "Green": "G", "Matte Black": "MK",
}

PRESETS = {
    "4":  ["Cyan", "Magenta", "Yellow", "Black"],
    "6":  ["Cyan", "Magenta", "Yellow", "Black", "Light Cyan", "Light Magenta"],
    "8":  ["Cyan", "Magenta", "Yellow", "Black", "Light Cyan", "Light Magenta",
            "Light Black", "Light Lt Black"],
    "11": ["Cyan", "Magenta", "Yellow", "Black", "Light Cyan", "Light Magenta",
            "Light Black", "Light Lt Black", "Red", "Blue", "Matte Black"],
    "12": ["Cyan", "Magenta", "Yellow", "Black", "Light Cyan", "Light Magenta",
            "Light Black", "Light Lt Black", "Red", "Blue", "Green", "Matte Black"],
}


def lighten(colour, factor=0.55):
    """Return a lighter version of the colour (mix towards white)."""
    return tuple(int(c + (255 - c) * factor) for c in colour)


def blend(c1, c2, t):
    """Linearly interpolate between two RGB colours."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def stagger_order(channels):
    """Reorder channels so adjacent ones are maximally different.
    Avoids heating the same part of the print head continuously."""
    if len(channels) <= 2:
        return channels
    evens = channels[::2]
    odds = channels[1::2]
    return evens + odds


class Canvas:
    """Draws on a Pillow image with coordinates in layout units."""

    def __init__(self, img, scale):
        self.draw = ImageDraw.Draw(img)
        self.scale = scale  # pixels per unit

    def px(self, v):
        return round(v * self.scale)

    def font(self, filename, size):
        try:
            return ImageFont.truetype(os.path.join(FONT_DIR, filename), self.px(size))
        except OSError:
            return ImageFont.load_default()

    def text(self, x, y, text, fill, font):
        self.draw.text((self.px(x), self.px(y)), text, fill=fill, font=font)

    def box(self, x0, y0, x1, y1, fill):
        """Fill from (x0, y0) to (x1, y1) inclusive, like ImageDraw.rectangle in units."""
        self.draw.rectangle([self.px(x0), self.px(y0), self.px(x1 + 1) - 1, self.px(y1 + 1) - 1],
                            fill=fill)

    def hline(self, x0, x1, y, fill):
        """A one-unit horizontal line from x0 to x1 inclusive, the same thickness everywhere."""
        top = self.px(y)
        self.draw.rectangle([self.px(x0), top, self.px(x1 + 1) - 1, top + max(1, round(self.scale)) - 1],
                            fill=fill)

    def gradient(self, x, y, w, h, c1, c2):
        """Fill w x h units at (x, y) with a left-to-right blend from c1 to c2."""
        x0, x1 = self.px(x), self.px(x + w)
        y0, y1 = self.px(y), self.px(y + h) - 1
        for col in range(x0, x1):
            t = (col - x0) / max(x1 - x0 - 1, 1)
            self.draw.line([(col, y0), (col, y1)], fill=blend(c1, c2, t))


def draw_nozzle_check(c, x, y, w, channels, font):
    """Draw fine staggered horizontal lines per channel — nozzle check style.
    Each channel gets 4 thin lines (1 unit) with 2-unit gaps, staggered by 1 unit."""
    section_y = y
    label_w = 18  # short label like "C", "M", etc.
    line_x = x + label_w + 4
    line_w = w - label_w - 4
    num_lines = 4
    line_spacing = 3  # 1-unit line + 2-unit gap

    for i, ch_name in enumerate(channels):
        colour = CHANNELS[ch_name]
        abbr = ABBREVS.get(ch_name, ch_name[:2])
        stagger = i % 3  # offset lines by 0-2 units to test different nozzles

        c.text(x, section_y, abbr, colour, font)
        for line_num in range(num_lines):
            ly = section_y + stagger + line_num * line_spacing
            c.hline(line_x, line_x + line_w, ly, colour)

        section_y += num_lines * line_spacing + 4

    return section_y - y


def draw_colour_patches(c, x, y, w, channels, font):
    """Draw tiny colour patches — pure + light shade in a compact 3-column grid.
    Each patch is just 6 units tall to minimise ink."""
    patch_h = 6
    row_gap = 2
    cols = 3
    col_w = (w - (cols - 1) * 4) // cols
    patch_w = col_w - 30  # room for short label
    section_y = y

    for i in range(0, len(channels), cols):
        for col in range(cols):
            idx = i + col
            if idx >= len(channels):
                break
            ch_name = channels[idx]
            colour = CHANNELS[ch_name]
            light = lighten(colour)
            cx = x + col * (col_w + 4)

            abbr = ABBREVS.get(ch_name, ch_name[:2])
            c.text(cx, section_y, abbr, (100, 100, 100), font)

            px = cx + 30
            half = patch_w // 2
            c.box(px, section_y, px + half - 1, section_y + patch_h, colour)
            c.box(px + half + 1, section_y, px + patch_w, section_y + patch_h, light)

        section_y += patch_h + row_gap

    return section_y - y


def draw_blend_strips(c, x, y, w, channels):
    """Draw thin horizontal gradient strips blending adjacent channels.
    Each strip is 2 units tall — just enough to fire both channels at varying ratios."""
    strip_h = 2
    strip_gap = 2
    section_y = y

    # Create pairs of adjacent channels for blending
    pairs = []
    for i in range(len(channels) - 1):
        pairs.append((channels[i], channels[i + 1]))
    # Also blend first and last to close the loop
    if len(channels) > 2:
        pairs.append((channels[-1], channels[0]))

    for ch1_name, ch2_name in pairs:
        c.gradient(x, section_y, w, strip_h, CHANNELS[ch1_name], CHANNELS[ch2_name])
        section_y += strip_h + strip_gap

    return section_y - y


def render_preset(name, width_px):
    """Draw preset `name` (a key of PRESETS) width_px pixels wide and return the image."""
    channel_names = PRESETS[name]
    # Stagger the channel order for nozzle check section
    staggered = stagger_order(channel_names)

    # Calculate heights for each section
    n = len(channel_names)
    nozzle_h = n * (4 * 3 + 4)  # 4 lines * 3-unit spacing + 4-unit gap per channel
    patch_rows = (n + 2) // 3   # 3 columns now
    patch_h = patch_rows * (6 + 2)
    blend_pairs = n  # n-1 adjacent + 1 wraparound (or n-1 if <=2)
    blend_h = blend_pairs * (2 + 2)

    title_h = 28
    section_label_h = 16
    total_h = (MARGIN + title_h
               + section_label_h + nozzle_h + 6
               + section_label_h + patch_h + 6
               + section_label_h + blend_h + 6
               + 20 + MARGIN)

    scale = width_px / WIDTH
    img = Image.new("RGB", (width_px, round(total_h * scale)), (255, 255, 255))
    c = Canvas(img, scale)
    font_title = c.font("DejaVuSans-Bold.ttf", 14)
    font_section = c.font("DejaVuSans-Bold.ttf", 10)
    font_tiny = c.font("DejaVuSans.ttf", 8)

    content_w = WIDTH - 2 * MARGIN
    y = MARGIN

    # Title
    c.text(MARGIN, y, f"Maintenance Print — {name}-Colour", (35, 31, 32), font_title)
    y += title_h

    # Section 1: Nozzle Check Lines
    c.text(MARGIN, y, "NOZZLE CHECK", (120, 120, 120), font_section)
    y += section_label_h
    h = draw_nozzle_check(c, MARGIN, y, content_w, staggered, font_tiny)
    y += h + 6

    # Section 2: Colour Patches (pure + light)
    c.text(MARGIN, y, "COLOUR PATCHES", (120, 120, 120), font_section)
    y += section_label_h
    h = draw_colour_patches(c, MARGIN, y, content_w, channel_names, font_tiny)
    y += h + 6

    # Section 3: Blend Strips
    c.text(MARGIN, y, "CHANNEL BLENDS", (120, 120, 120), font_section)
    y += section_label_h
    h = draw_blend_strips(c, MARGIN, y, content_w, channel_names)
    y += h + 6

    # Footer
    c.text(MARGIN, total_h - MARGIN - 10, "print-blockage-stopper — low-ink maintenance print",
           (180, 180, 180), font_tiny)

    return img


def main():
    output_dir = sys.argv[1] if len(sys.argv) > 1 else "/app/presets"
    os.makedirs(output_dir, exist_ok=True)
    width_px = round(WIDTH / 72 * PNG_DPI)
    for name in PRESETS:
        img = render_preset(name, width_px)
        out_path = os.path.join(output_dir, f"preset-{name}.png")
        img.save(out_path, "PNG", optimize=True, dpi=(PNG_DPI, PNG_DPI))
        print(f"Generated {out_path} ({img.size[0]}x{img.size[1]})")
    print(f"All presets generated in {output_dir}")


if __name__ == "__main__":
    main()
