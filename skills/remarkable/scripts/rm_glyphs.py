#!/usr/bin/env python3
"""Turn a line of text into filled outlines.

A cover's title has to be heavy and identical in the PDF and in the on-device
template. The template DSL has no font selection and no bold — it takes a font
size and whatever face the firmware picks — so a title drawn as a `text` item
is out of our hands, and it is also the item whose `fontSize` rules have bitten
this skill before.

Drawing the letters as *shapes* removes both problems: the same Helvetica-Bold
glyphs, at the same size, in both outputs, with no font on the device involved.

The outlines come out of PyMuPDF, which will write a page's text as SVG paths:

    <defs><path id="font_1_37" d="M.0769 0H.3619C.4729 0 ..."/></defs>
    <use xlink:href="#font_1_37" transform="matrix(40,0,0,-40,40,100)"/>

The def is one glyph in em space (0..1, y up); the matrix scales it and flips y,
so applying it lands the glyph directly in page coordinates. Counters (the hole
in a D) are separate subpaths wound the other way, which is why the caller must
fill the whole set as one shape with an even-odd rule rather than one at a time.
"""

from __future__ import annotations

import pathlib
import re

import pymupdf

_NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
_CMD = re.compile(r"([MmLlHhVvCcSsQqTtZz])")
_DEF = re.compile(r'<path id="([^"]+)" d="([^"]*)"/>')
_USE = re.compile(r'<use[^>]*?xlink:href="#([^"]+)"[^>]*?'
                  r'transform="matrix\(([^)]*)\)"[^>]*/>')

CURVE_STEPS = 10        # per Bezier segment; at title size this is well past
                        # the point where more segments change a rendered pixel


def _tokens(d):
    """Split an SVG path `d` into (command, [numbers]) pairs."""
    out = []
    for part in filter(None, (s.strip() for s in _CMD.split(d))):
        if len(part) == 1 and part.isalpha():
            out.append([part, []])
        elif out:
            out[-1][1].extend(float(n) for n in _NUM.findall(part))
    return out


def _cubic(p0, p1, p2, p3):
    pts = []
    for i in range(1, CURVE_STEPS + 1):
        t = i / CURVE_STEPS
        s = 1 - t
        pts.append((s*s*s*p0[0] + 3*s*s*t*p1[0] + 3*s*t*t*p2[0] + t*t*t*p3[0],
                    s*s*s*p0[1] + 3*s*s*t*p1[1] + 3*s*t*t*p2[1] + t*t*t*p3[1]))
    return pts


def _subpaths(d):
    """Flatten one glyph's path data into closed point lists, in em space."""
    paths, cur = [], []
    x = y = sx = sy = 0.0
    prev_ctrl = None

    def flush():
        nonlocal cur
        if len(cur) > 2:
            paths.append(cur)
        cur = []

    for cmd, a in _tokens(d):
        rel = cmd.islower()
        c = cmd.upper()
        i = 0
        while True:
            if c == "Z":
                flush()
                x, y = sx, sy
                prev_ctrl = None
                break
            if c in "ML":
                if i + 2 > len(a):
                    break
                nx, ny = a[i] + (x if rel else 0), a[i+1] + (y if rel else 0)
                if c == "M" and i == 0:
                    flush()
                    sx, sy = nx, ny
                    cur = [(nx, ny)]
                else:
                    cur.append((nx, ny))
                x, y, i = nx, ny, i + 2
                prev_ctrl = None
            elif c in "HV":
                if i + 1 > len(a):
                    break
                if c == "H":
                    x = a[i] + (x if rel else 0)
                else:
                    y = a[i] + (y if rel else 0)
                cur.append((x, y))
                i += 1
                prev_ctrl = None
            elif c in "CS":
                need = 6 if c == "C" else 4
                if i + need > len(a):
                    break
                ox, oy = (x, y) if rel else (0.0, 0.0)
                if c == "C":
                    c1 = (a[i] + ox, a[i+1] + oy)
                    c2 = (a[i+2] + ox, a[i+3] + oy)
                    nx, ny = a[i+4] + ox, a[i+5] + oy
                else:
                    c1 = (2*x - prev_ctrl[0], 2*y - prev_ctrl[1]) if prev_ctrl else (x, y)
                    c2 = (a[i] + ox, a[i+1] + oy)
                    nx, ny = a[i+2] + ox, a[i+3] + oy
                cur.extend(_cubic((x, y), c1, c2, (nx, ny)))
                x, y, prev_ctrl, i = nx, ny, c2, i + need
            elif c in "QT":
                need = 4 if c == "Q" else 2
                if i + need > len(a):
                    break
                ox, oy = (x, y) if rel else (0.0, 0.0)
                if c == "Q":
                    q = (a[i] + ox, a[i+1] + oy)
                    nx, ny = a[i+2] + ox, a[i+3] + oy
                else:
                    q = (2*x - prev_ctrl[0], 2*y - prev_ctrl[1]) if prev_ctrl else (x, y)
                    nx, ny = a[i] + ox, a[i+1] + oy
                # a quadratic is a cubic with the control points pulled 2/3 in
                cur.extend(_cubic((x, y),
                                  (x + 2/3*(q[0]-x), y + 2/3*(q[1]-y)),
                                  (nx + 2/3*(q[0]-nx), ny + 2/3*(q[1]-ny)),
                                  (nx, ny)))
                x, y, prev_ctrl, i = nx, ny, q, i + need
            else:
                break
            if i >= len(a):
                break
    flush()
    return paths


# Monochrome emoji, in preference order. Segoe UI Emoji is a colour (COLR/CPAL)
# font, but its *base* glyph layer is a clean black silhouette — which is
# exactly what a 16-level greyscale panel wants, and what comes back when the
# outlines are extracted rather than the font being rendered normally.
EMOJI_FONTS = (
    "C:/Windows/Fonts/seguiemj.ttf",              # Segoe UI Emoji, Windows
    "C:/Windows/Fonts/seguisym.ttf",              # Segoe UI Symbol, fallback
    "/System/Library/Fonts/Apple Color Emoji.ttc",
    "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
)


def emoji_font():
    for p in EMOJI_FONTS:
        if pathlib.Path(p).exists():
            return p
    return None


def text_width(s, size, fontname="Helvetica-Bold"):
    return pymupdf.get_text_length(s, fontname=fontname, fontsize=size)


def outlines(s, size, x=0.0, y=0.0, fontname="Helvetica-Bold", tracking=0.0,
             fontfile=None):
    """Subpaths for `s` with its baseline starting at (x, y), in page points.

    `tracking` adds letter spacing as a fraction of the size — a little of it
    makes a heavy uppercase title read as a poster rather than a word.
    `fontfile` loads any TTF on the machine; `fontname` is then just the label
    PyMuPDF caches it under.
    """
    if not s:
        return []

    # Draw somewhere with plenty of room, then translate; the page only exists
    # so that PyMuPDF will hand back the glyph outlines.
    doc = pymupdf.open()
    page = doc.new_page(width=4000, height=1000)
    ox, oy = 20.0, 600.0
    kw = {"fontfile": fontfile, "fontname": fontname} if fontfile else {"fontname": fontname}
    if tracking and not fontfile:
        pen = ox
        for ch in s:
            page.insert_text((pen, oy), ch, fontsize=size, **kw)
            pen += text_width(ch, size, fontname) + size * tracking
    else:
        page.insert_text((ox, oy), s, fontsize=size, **kw)

    svg = page.get_svg_image(text_as_path=True)
    doc.close()

    glyphs = {gid: _subpaths(d) for gid, d in _DEF.findall(svg)}
    dx, dy = x - ox, y - oy

    out = []
    for gid, mat in _USE.findall(svg):
        a, b, c, d, e, f = (float(v) for v in mat.split(","))
        for sub in glyphs.get(gid, ()):
            out.append([(a*px + c*py + e + dx, b*px + d*py + f + dy)
                        for px, py in sub])
    return out


def advance(s, size, fontname="Helvetica-Bold", tracking=0.0):
    """Width of `s` as `outlines` will lay it out, trailing tracking removed."""
    if not s:
        return 0.0
    w = text_width(s, size, fontname)
    return w + size * tracking * (len(s) - 1)


def bbox(subpaths):
    """(x0, y0, x1, y1) of a set of subpaths, or None if there is nothing."""
    pts = [p for sub in subpaths for p in sub]
    if not pts:
        return None
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def fit(subpaths, x, y, w, h):
    """Scale and centre subpaths into the box, keeping their aspect ratio.

    Emoji come out of the font with wildly different ink extents — a 📊 fills
    its em box, a 💡 is tall and narrow — so placing them on advance width
    alone leaves them visibly off-centre and unequal. Fitting the actual ink
    box is what makes a row of them look deliberate.
    """
    b = bbox(subpaths)
    if not b:
        return []
    bx0, by0, bx1, by1 = b
    bw, bh = max(bx1 - bx0, 1e-6), max(by1 - by0, 1e-6)
    s = min(w / bw, h / bh)
    dx = x + (w - bw * s) / 2 - bx0 * s
    dy = y + (h - bh * s) / 2 - by0 * s
    return [[(px * s + dx, py * s + dy) for px, py in sub] for sub in subpaths]


def emoji_outlines(ch, box_w, box_h, x=0.0, y=0.0, fontfile=None):
    """One emoji, fitted into a box. Single code points only — a ZWJ sequence
    (👨‍💻) has no single glyph to take outlines from and comes back empty."""
    fontfile = fontfile or emoji_font()
    if not fontfile:
        raise RuntimeError("No emoji font found. Looked in:\n  " +
                           "\n  ".join(EMOJI_FONTS))
    raw = outlines(ch, 200.0, 0.0, 0.0, fontname="emoji", fontfile=fontfile)
    return fit(raw, x, y, box_w, box_h)
