#!/usr/bin/env python3
"""Build a reMarkable-native template PDF from a small JSON spec.

Page geometry is the device's own: 445 x 594 pt (157.0 x 209.5 mm), the exact
size reMarkable writes when it exports a notebook, and a 3:4 ratio that fills
the screen with no letterboxing on both reMarkable 2 and Paper Pro.

Everything is vector, so it stays sharp at any zoom, and it uses only the PDF
base-14 fonts, so nothing has to be embedded and nothing can fail to load.

Usage:
    python make_template.py templates/standup.json -o standup.pdf
    python make_template.py templates/standup.json -o standup.pdf --pages 60
    python make_template.py templates/standup.json -o out.pdf --preview out.png
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_glyphs                                    # noqa: E402
import rm_icons                                     # noqa: E402

try:
    import pymupdf
except ImportError:  # pragma: no cover
    try:
        import fitz as pymupdf
    except ImportError:
        sys.exit("PyMuPDF is required.\n  python -m pip install pymupdf")

# --- device geometry ---------------------------------------------------------
# Measured from PDFs the tablet itself exported, not derived from pixel specs.
PAGE_W, PAGE_H = 445.0, 594.0

# Panel resolutions, for exporting a real installed template (which is an image
# at native resolution, not a PDF). Both are 3:4, same as the page above.
DEVICE_PX = {
    "rm2": (1404, 1872),   # reMarkable 1 and 2
    "pp":  (1620, 2160),   # reMarkable Paper Pro
}

# --- ink levels --------------------------------------------------------------
# The rM2 panel is 16-level greyscale. Below roughly 0.80 grey a rule stops
# being visible in daylight; above 0.55 it competes with your handwriting.
INK_TEXT = (0.10, 0.10, 0.10)
INK_HEAD = (0.28, 0.28, 0.28)   # section headings
INK_RULE = (0.68, 0.68, 0.68)   # writing lines
INK_EDGE = (0.52, 0.52, 0.52)   # box borders, field underlines
INK_DOT = (0.76, 0.76, 0.76)
INK_LINE = rm_icons.INK_LINE    # cover artwork outlines — near black, heavy
INK_BAND = (0.80, 0.80, 0.80)   # the title banner and the icon fills

# Drop below a section heading before the first writing slot begins. Tuned so
# that first slot is the same height as every slot after it — you write *above*
# a rule, so an over-generous drop makes the first line sit oddly low.
HEAD_DROP = 4.0

# The pinned toolbar floats OVER the page, it does not push it aside, so the
# margin on its side has to clear it or your first words sit underneath.
# It is about 120 px wide and the advice is to keep 130 px free; the page is
# 445 pt across a 1404 px screen, so 130 px = 445/1404 * 130 = 41.2 pt.
# 44 gives a little slack without eating much writing width.
TOOLBAR_CLEAR = 44.0
MARGIN_PLAIN = 30.0

DEFAULTS = {
    "toolbar": "left",     # "left", "right", or "none" if you keep it hidden
    "margin_left": None,   # None => derived from `toolbar`
    "margin_right": None,
    "margin_top": 30.0,
    "margin_bottom": 26.0,
    "line_gap": 26.0,      # ~9.2 mm — comfortable adult handwriting
    "rule_width": 0.6,
    "head_size": 8.5,
    "gap": 14.0,           # vertical space between blocks
}


def resolve_margins(cfg, spec):
    """Work out left/right margins from the toolbar side, unless pinned."""
    side = str(spec.get("toolbar", cfg["toolbar"])).lower()
    if side not in ("left", "right", "none"):
        sys.exit(f'toolbar must be "left", "right" or "none", not {side!r}')

    left = TOOLBAR_CLEAR if side == "left" else MARGIN_PLAIN
    right = TOOLBAR_CLEAR if side == "right" else MARGIN_PLAIN

    # margin_x is a shorthand that overrides both; explicit sides win over it.
    if "margin_x" in spec:
        left = right = float(spec["margin_x"])
    if spec.get("margin_left") is not None:
        left = float(spec["margin_left"])
    if spec.get("margin_right") is not None:
        right = float(spec["margin_right"])
    return left, right


# reMarkable's own template DSL works in device pixels: 1 unit = 1 px on a
# 1404-wide portrait page. Confirmed three ways against a real device —
# a stock template's group x of (1404-1872)/2 = -234 units lands at -74.2 pt in
# an exported notebook, "P US College"'s 62-unit repeat lands at 19.7 pt, and
# that is the template the notebooks were actually written on.
UNITS_PER_PT = DEVICE_PX["rm2"][0] / PAGE_W      # 3.1551


class Canvas:
    """Drawing surface. Subclasses render to a PDF page or to the device DSL.

    Everything the block renderers draw goes through these primitives, so one
    layout produces either output with no branching in the renderers.
    """

    def __init__(self, cfg):
        self.cfg = cfg

    # -- primitives, implemented by subclasses --
    def line(self, x0, y0, x1, y1, ink=INK_RULE, width=None): ...
    def rect(self, x0, y0, x1, y1, ink=INK_EDGE, width=0.7): ...
    def text(self, x, y, s, size, bold=False, ink=INK_HEAD): ...

    def shape(self, subpaths, ink=None, width=0.6, fill=None, close=True):
        """One filled/stroked shape made of several point lists.

        Several subpaths in *one* shape, rather than one shape each, because
        that is what makes a hole a hole: a glyph counter and an icon cut-out
        are wound the opposite way to their outline, and only an even-odd fill
        over the whole set leaves them empty. Drawn separately they fill solid.
        """
        raise NotImplementedError

    def rows(self, x, y_first, w, gap, n, checks=False):
        """n evenly spaced writing rows, optionally each with a checkbox."""
        raise NotImplementedError

    def dots(self, x, y, w, h, step):
        raise NotImplementedError

    # -- shared helpers --
    def rule(self, x0, y, x1, ink=INK_RULE, width=None):
        self.line(x0, y, x1, y, ink, width or self.cfg["rule_width"])

    def heading(self, x, y, text):
        self.text(x, y, text.upper(), self.cfg["head_size"], bold=True, ink=INK_HEAD)

    def label(self, x, y, text, size=8.0):
        self.text(x, y, text, size, ink=INK_HEAD)


class PdfCanvas(Canvas):
    def __init__(self, page, cfg):
        super().__init__(cfg)
        self.p = page

    def line(self, x0, y0, x1, y1, ink=INK_RULE, width=None):
        self.p.draw_line((x0, y0), (x1, y1), color=ink,
                         width=width or self.cfg["rule_width"])

    def rect(self, x0, y0, x1, y1, ink=INK_EDGE, width=0.7):
        self.p.draw_rect(pymupdf.Rect(x0, y0, x1, y1), color=ink, width=width)

    def text(self, x, y, s, size, bold=False, ink=INK_HEAD):
        self.p.insert_text((x, y), s, fontsize=size, color=ink,
                           fontname="Helvetica-Bold" if bold else "Helvetica")

    def rows(self, x, y_first, w, gap, n, checks=False):
        for i in range(n):
            ly = y_first + i * gap
            if checks:
                self.rect(x, ly - 12.0, x + 9.0, ly - 3.0)
                self.rule(x + 15.0, ly, x + w)
            else:
                self.rule(x, ly, x + w)

    def shape(self, subpaths, ink=None, width=0.6, fill=None, close=True):
        sh = self.p.new_shape()
        drew = False
        for pts in subpaths:
            if len(pts) < 2:
                continue
            pts = list(pts) + ([pts[0]] if close and pts[0] != pts[-1] else [])
            sh.draw_polyline([pymupdf.Point(*p) for p in pts])
            drew = True
        if not drew:
            return
        # closePath=False: every subpath already carries its own closing point,
        # whereas Shape.finish would only close the last one.
        sh.finish(color=ink, fill=fill, width=max(width, 0.1) if ink else 0,
                  closePath=False, even_odd=True, lineCap=1, lineJoin=1)
        sh.commit()

    def dots(self, x, y, w, h, step):
        yy = y + step / 2
        while yy < y + h - 2:
            xx = x + step / 2
            while xx < x + w - 2:
                self.p.draw_circle((xx, yy), 0.55, color=INK_DOT,
                                   fill=INK_DOT, width=0)
                xx += step
            yy += step


def icon_svg(spec, cfg, margin_left, margin_right):
    """A 150x200 schematic of the layout, for the template picker.

    reMarkable's own Methods templates carry one of these as base64 in
    `iconData`, and the same SVG again as the entry's thumbnail. It is a
    diagram of the page, not a rendering of it — outlined regions, no text.
    """
    W, H = 150.0, 200.0
    blocks = spec.get("blocks", [])
    body_h = PAGE_H - cfg["margin_top"] - cfg["margin_bottom"]
    sx, sy = W / PAGE_W, H / PAGE_H

    fixed = sum(natural_height(b, cfg) for b in blocks if not b.get("fill"))
    fixed += cfg["gap"] * max(len(blocks) - 1, 0)
    fillers = [b for b in blocks if b.get("fill")]
    each = max(body_h - fixed, 0.0) / len(fillers) if fillers else 0.0

    parts = [f'<rect x="2" y="2" width="{W-4:g}" height="{H-4:g}" '
             f'fill="none" stroke="black" stroke-width="4"/>']

    if any(b.get("type") == "cover" for b in blocks):
        # The schematic is the cover itself: a title bar and one mass.
        parts.append('<rect x="18" y="16" width="114" height="26" fill="black"/>')
        parts.append('<circle cx="75" cy="118" r="46" fill="black"/>')
        return ('<svg width="150" height="200" viewBox="0 0 150 200" fill="none" '
                'xmlns="http://www.w3.org/2000/svg">' + "".join(parts) + "</svg>")

    y = cfg["margin_top"]
    for b in blocks:
        h = each if b.get("fill") else natural_height(b, cfg)
        bx, bw = margin_left, PAGE_W - margin_left - margin_right
        if b.get("type") == "row":
            cols = b["columns"]
            total = sum(float(c.get("width", 1)) for c in cols)
            cx = bx
            for c in cols:
                cw = (bw - cfg["gap"] * (len(cols) - 1)) * float(c.get("width", 1)) / total
                parts.append(f'<rect x="{cx*sx:.1f}" y="{y*sy:.1f}" '
                             f'width="{cw*sx:.1f}" height="{h*sy:.1f}" '
                             f'fill="none" stroke="black" stroke-width="3"/>')
                cx += cw + cfg["gap"]
        elif b.get("type") == "header":
            parts.append(f'<rect x="{bx*sx:.1f}" y="{y*sy:.1f}" '
                         f'width="{bw*sx:.1f}" height="{h*sy:.1f}" fill="black"/>')
        else:
            parts.append(f'<rect x="{bx*sx:.1f}" y="{y*sy:.1f}" '
                         f'width="{bw*sx:.1f}" height="{h*sy:.1f}" '
                         f'fill="none" stroke="black" stroke-width="3"/>')
        y += h + cfg["gap"]

    return ('<svg width="150" height="200" viewBox="0 0 150 200" fill="none" '
            'xmlns="http://www.w3.org/2000/svg">' + "".join(parts) + "</svg>")


def _hex(ink):
    return "#{:02x}{:02x}{:02x}".format(*(int(round(c * 255)) for c in ink))


class TemplateCanvas(Canvas):
    """Emits reMarkable's own .template DSL: constants-free, absolute units."""

    def __init__(self, cfg):
        super().__init__(cfg)
        self.items = []

    @staticmethod
    def u(v):
        return round(v * UNITS_PER_PT, 2)

    def _path(self, data, ink, width):
        item = {"type": "path", "data": data}
        if ink is not None:
            item["strokeColor"] = _hex(ink)
        if width:
            # Integer, like every stock template. The parser rejects a
            # non-integer fontSize outright; strokeWidth is not worth the risk.
            item["strokeWidth"] = max(1, int(round(width * UNITS_PER_PT)))
        return item

    def line(self, x0, y0, x1, y1, ink=INK_RULE, width=None):
        self.items.append(self._path(
            ["M", self.u(x0), self.u(y0), "L", self.u(x1), self.u(y1)],
            ink, width or self.cfg["rule_width"]))

    def rect(self, x0, y0, x1, y1, ink=INK_EDGE, width=0.7):
        X0, Y0, X1, Y1 = self.u(x0), self.u(y0), self.u(x1), self.u(y1)
        self.items.append(self._path(
            ["M", X0, Y0, "L", X1, Y0, "L", X1, Y1, "L", X0, Y1, "Z"], ink, width))

    def text(self, x, y, s, size, bold=False, ink=INK_HEAD):
        # The DSL has no font selection; bold is approximated by the device font.
        # fontSize MUST be a positive integer. A float makes the device refuse
        # the whole file — "error: 'fontSize' must be a positive value" — and the
        # template then renders as a completely blank page, which looks like a
        # layout bug rather than a parse failure. Every stock template uses an
        # integer (24, 25, 32, 72).
        self.items.append({
            "type": "text", "text": s,
            "fontSize": max(1, int(round(size * UNITS_PER_PT))),
            "position": {"x": self.u(x), "y": self.u(y)},
        })

    def shape(self, subpaths, ink=None, width=0.6, fill=None, close=True):
        data = []
        for pts in subpaths:
            if len(pts) < 2:
                continue
            data += ["M", self.u(pts[0][0]), self.u(pts[0][1])]
            for px, py in pts[1:]:
                data += ["L", self.u(px), self.u(py)]
            if close:
                data.append("Z")
        if not data:
            return
        item = {"type": "path", "data": data}
        # A fill with no stroke leaves the shape a hairline short of its
        # outline, so an unstroked fill borrows its own colour for the edge.
        stroke = ink if ink is not None else fill
        if stroke is not None:
            item["strokeColor"] = _hex(stroke)
            item["strokeWidth"] = max(1, int(round(
                (width if ink is not None else 0.3) * UNITS_PER_PT)))
        if fill is not None:
            item["fillColor"] = _hex(fill)
        self.items.append(item)

    def rows(self, x, y_first, w, gap, n, checks=False):
        """One repeat-group instead of n separate paths — idiomatic, and small."""
        data = []
        if checks:
            data += ["M", self.u(0), self.u(-12.0),
                     "L", self.u(9.0), self.u(-12.0),
                     "L", self.u(9.0), self.u(-3.0),
                     "L", self.u(0), self.u(-3.0), "Z"]
            data += ["M", self.u(15.0), 0, "L", self.u(w), 0]
        else:
            data += ["M", 0, 0, "L", self.u(w), 0]

        self.items.append({
            "type": "group",
            "boundingBox": {"x": self.u(x), "y": self.u(y_first),
                            "width": self.u(w), "height": self.u(gap)},
            "repeat": {"rows": n},
            "children": [self._path(data, INK_RULE, self.cfg["rule_width"])],
        })

    def dots(self, x, y, w, h, step):
        cols = max(int((w - step) // step), 1)
        rows_n = max(int((h - step) // step), 1)
        d = self.u(1.1)                       # a dot, drawn as a tiny square
        self.items.append({
            "type": "group",
            "boundingBox": {"x": self.u(x + step / 2), "y": self.u(y + step / 2),
                            "width": self.u(step), "height": self.u(step)},
            "repeat": {"rows": rows_n, "columns": cols},
            "children": [{
                "type": "path",
                "strokeColor": _hex(INK_DOT),
                "fillColor": _hex(INK_DOT),
                "strokeWidth": max(1, int(round(d))),
                "data": ["M", 0, 0, "L", d, 0, "L", d, d, "L", 0, d, "Z"],
            }],
        })

    def document(self, name, category, icon=None, labels=None,
                 orientation="portrait"):
        doc = {
            "name": name,
            "author": "make_template.py",
            "templateVersion": "1.0.0",
            "formatVersion": 1,
            "categories": [category],
            "orientation": orientation,
            "items": self.items,
        }
        if labels:
            doc["labels"] = labels
        if icon:
            # Key order matters only for readability; the device does not care.
            doc = {**{k: doc[k] for k in ("name", "author")},
                   "iconData": base64.b64encode(icon.encode("utf-8")).decode("ascii"),
                   **{k: v for k, v in doc.items() if k not in ("name", "author")}}
        return doc


# --- block renderers ---------------------------------------------------------
# Each returns the height it wants; draw=False measures without drawing.

def _lines_height(spec, cfg):
    n = int(spec.get("lines", 4))
    gap = float(spec.get("line_gap", cfg["line_gap"]))
    head = HEAD_DROP + 5.0 if spec.get("title") else 0.0
    return head + n * gap


def render_section(cv, spec, x, y, w, h, cfg):
    """A titled block of writing lines, checkboxes, dots, a grid, or nothing."""
    style = spec.get("style", "lines")
    gap = float(spec.get("line_gap", cfg["line_gap"]))
    top = y

    if spec.get("title"):
        cv.heading(x, y + 8.5, spec["title"])
        y += HEAD_DROP + 5.0

    if style == "blank":
        return

    if style == "box":
        cv.rect(x, y, x + w, top + h)
        return

    if style == "dots":
        cv.dots(x, y, w, top + h - y, float(spec.get("step", 16.0)))
        return

    if style == "grid":
        step = float(spec.get("step", 18.0))
        yy = y
        while yy <= top + h:
            cv.rule(x, yy, x + w)
            yy += step
        xx = x
        while xx <= x + w:
            cv.line(xx, y, xx, top + h, INK_RULE, cfg["rule_width"])
            xx += step
        return

    # lines / checks — fill the available height rather than a fixed count
    n = int((top + h - y) // gap)
    if spec.get("lines"):
        n = min(n, int(spec["lines"]))
    if n > 0:
        cv.rows(x, y + gap, w, gap, n, checks=(style == "checks"))


def render_header(cv, spec, x, y, w, h, cfg):
    """Title on the left, labelled fill-in fields on the right."""
    title = spec.get("title", "")
    fields = spec.get("fields", [])

    baseline = y + 15.0
    tw = 0.0
    if title:
        size = float(spec.get("size", 15.0))
        cv.text(x, baseline, title, size, bold=True, ink=INK_TEXT)
        tw = pymupdf.get_text_length(title, "Helvetica-Bold", size) + 18.0

    if fields:
        avail = w - tw
        total_flex = sum(float(f.get("flex", 1)) for f in fields)
        fx = x + tw
        for f in fields:
            fw = avail * float(f.get("flex", 1)) / total_flex - 10.0
            cv.label(fx, baseline, f["label"] + " ", size=8.0)
            lw = pymupdf.get_text_length(f["label"] + " ", "Helvetica", 8.0)
            cv.rule(fx + lw, baseline + 2.0, fx + fw, ink=INK_EDGE, width=0.7)
            fx += fw + 10.0

    # the heavy rule that separates the header from the body
    cv.rule(x, y + h - 6.0, x + w, ink=INK_HEAD, width=1.0)


def render_rule(cv, spec, x, y, w, h, cfg):
    cv.rule(x, y + h / 2, x + w, ink=INK_EDGE, width=0.7)


# Where satellite icons go, in order: corners first, then the sides, then the
# remaining diagonals. Angles are counter-clockwise from 3 o'clock, so a
# positive one is above the centre. Filling corners first keeps a three- or
# four-icon cover from looking like a row of buttons.
SAT_SLOTS = (135, 45, 180, 0, -135, -45, 90, -90)


# Title cap height as a fraction of the em, for Helvetica. Positioning an
# all-caps line on this rather than on the em box is what stops it sitting
# visibly low inside its slot.
CAP_HEIGHT = 0.717

# The title stops growing here however short it is. Without a cap, "Ops" would
# be set at 130 pt and read as shouting rather than as a label.
TITLE_MAX = 78.0

# Emoji box, as a fraction of the page width. At 0.70 the silhouette spans
# about 82 of the thumbnail's 118 px, which is what makes it register as a
# shape before the title is legible as a word.
EMOJI_FRACTION = 0.70


def render_cover(cv, spec, x, y, w, h, cfg):
    """Title at the top, one emoji in the middle. Nothing else.

    The first page of a notebook is its thumbnail in the library, about 20 mm
    wide, and the design follows entirely from that. Every element that was
    here before — the frame, the grey title banner, the footer date rule —
    was either invisible at that size or actively cost contrast:

    - a grey band drops the title from black-on-white to black-on-grey, which
      measurably weakens it at 118 px;
    - a hollow (stroked) emoji collapses, because a 4 pt stroke is about 1 px;
    - a rule renders as a hard 1 px bar that competes with the artwork and
      carries no information.

    So: two marks, pure black on white, with clear space between them. The
    shape is what finds the notebook among thirty-five; the word confirms it.
    Ring-shaped emoji (compass, gear, target) all collapse into the same dark
    donut at thumbnail size — prefer a solid mass.
    """
    heading = str(spec.get("heading", spec.get("title", ""))).strip()
    if spec.get("uppercase", True):
        heading = heading.upper()

    # --- title, drawn as outlines rather than as a font ---
    base = y
    if heading:
        tracking = float(spec.get("tracking", 0.04))
        unit = rm_glyphs.advance(heading, 1.0, tracking=tracking)
        size = float(spec.get("title_size", 0.0)) or min(
            w / unit if unit else TITLE_MAX, float(spec.get("title_max", TITLE_MAX)))
        tw = rm_glyphs.advance(heading, size, tracking=tracking)
        base = y + CAP_HEIGHT * size
        cv.shape(rm_glyphs.outlines(heading, size, x + (w - tw) / 2, base,
                                    tracking=tracking), fill=INK_LINE)

    # --- the artwork ---
    emoji = spec.get("emoji")
    if isinstance(emoji, str):
        emoji = [c for c in emoji if not c.isspace()]
    icons = spec.get("icons") or []
    if not icons and not emoji:
        return

    ax0, ay0 = x, base + float(spec.get("title_gap", 40.0))
    ax1, ay1 = x + w, y + h
    aw, ah = ax1 - ax0, ay1 - ay0
    if aw <= 0 or ah <= 0:
        return
    cxc, cyc = ax0 + aw / 2, ay0 + ah / 2

    if emoji:
        if len(emoji) > 1:
            print(f"note: a cover shows one emoji; using the first of "
                  f"{len(emoji)}.", file=sys.stderr)
        box = min(PAGE_W * float(spec.get("emoji_scale", EMOJI_FRACTION)), aw, ah)
        sub = rm_glyphs.emoji_outlines(emoji[0], box, box,
                                       cxc - box / 2, cyc - box / 2)
        if not sub:
            print(f"note: no glyph for {emoji[0]!r} — a ZWJ sequence has no "
                  f"single outline; use a plain single-code-point emoji.",
                  file=sys.stderr)
        elif str(spec.get("emoji_style", "solid")).lower() == "outline":
            cv.shape(sub, ink=INK_LINE, width=max(box * 0.014, 0.8),
                     fill=(1.0, 1.0, 1.0))
        else:
            cv.shape(sub, fill=INK_LINE)
        return

    scale = float(spec.get("icon_scale", 1.0))
    weight = float(spec.get("icon_weight", 0.030))
    unknown = [n for n in icons if n not in rm_icons.REGISTRY]
    if unknown:
        sys.exit(f"Unknown icon(s): {', '.join(unknown)}.\n"
                 f"Available: {', '.join(rm_icons.names())}")

    if len(icons) == 1:
        s = min(aw, ah) * 0.88 * scale
        rm_icons.draw(cv, icons[0], cxc - s / 2, cyc - s / 2, s, weight)
        return

    hero = min(aw, ah) * 0.55 * scale
    sat = min(aw, ah) * 0.30 * scale
    rm_icons.draw(cv, icons[0], cxc - hero / 2, cyc - hero / 2, hero, weight)

    rx, ry = (aw - sat) / 2, (ah - sat) / 2
    for i, name in enumerate(icons[1:len(SAT_SLOTS) + 1]):
        a = math.radians(SAT_SLOTS[i])
        # Normalised on the larger component, not the vector length, so a
        # diagonal slot lands in the actual corner. Scale it down by the
        # circle and the four corners sit half an icon in from the frame,
        # which is the crowded look the first draft had.
        c, s = math.cos(a), math.sin(a)
        m = max(abs(c), abs(s))
        cx, cy = cxc + rx * c / m, cyc - ry * s / m
        rm_icons.draw(cv, name, cx - sat / 2, cy - sat / 2, sat, weight)

    if len(icons) > len(SAT_SLOTS) + 1:
        print(f"note: cover shows {len(SAT_SLOTS) + 1} of {len(icons)} icons; "
              f"the rest were dropped.", file=sys.stderr)


RENDERERS = {
    "header": render_header,
    "section": render_section,
    "rule": render_rule,
    "cover": render_cover,
    "spacer": lambda *a, **k: None,
}


def natural_height(spec, cfg):
    t = spec.get("type", "section")
    if "height" in spec:
        return float(spec["height"])
    if t == "header":
        return 34.0
    if t == "rule":
        return 10.0
    if t == "spacer":
        return float(spec.get("size", 12.0))
    if t == "cover":
        # A cover wants the whole page; this is only the fallback for a spec
        # that forgot "fill": true, and the overflow guard uses it as-is.
        return 420.0
    if t == "row":
        return max(column_height(c, cfg) for c in spec["columns"])
    return _lines_height(spec, cfg)


def column_height(col, cfg):
    blocks = col.get("blocks", [])
    if not blocks:
        return 0.0
    return sum(natural_height(b, cfg) for b in blocks) + cfg["gap"] * (len(blocks) - 1)


def layout(cv, blocks, x, y, w, avail_h, cfg):
    """Place blocks top to bottom; blocks marked fill share what is left."""
    fixed = [b for b in blocks if not b.get("fill")]
    fillers = [b for b in blocks if b.get("fill")]

    used = sum(natural_height(b, cfg) for b in fixed)
    used += cfg["gap"] * max(len(blocks) - 1, 0)
    spare = max(avail_h - used, 0.0)
    each = spare / len(fillers) if fillers else 0.0

    for b in blocks:
        h = each if b.get("fill") else natural_height(b, cfg)
        t = b.get("type", "section")
        if t == "row":
            cols = b["columns"]
            total_w = sum(float(c.get("width", 1)) for c in cols)
            cx = x
            for c in cols:
                cw = (w - cfg["gap"] * (len(cols) - 1)) * float(c.get("width", 1)) / total_w
                layout(cv, c.get("blocks", []), cx, y, cw, h, cfg)
                cx += cw + cfg["gap"]
        else:
            RENDERERS.get(t, render_section)(cv, b, x, y, w, h, cfg)
        y += h + cfg["gap"]


def build(spec, out_path, pages=None, preview=None,
          png=None, svg=None, device="rm2", template=None):
    cfg = dict(DEFAULTS)
    for k in cfg:
        if k in spec and k not in ("toolbar", "margin_left", "margin_right"):
            cfg[k] = float(spec[k])

    margin_left, margin_right = resolve_margins(cfg, spec)

    # A cover's headline is the document title unless it says otherwise, so
    # `--title "Dev leads"` names the template and letters the front in one go.
    for b in spec.get("blocks", []):
        if b.get("type") == "cover" and "heading" not in b:
            b["heading"] = spec.get("title", "")

    n_pages = int(pages or spec.get("pages", 1))
    doc = pymupdf.open()

    x = margin_left
    w = PAGE_W - margin_left - margin_right
    y = cfg["margin_top"]
    avail = PAGE_H - cfg["margin_top"] - cfg["margin_bottom"]

    # Refuse to draw past the bottom of the page. Silently overflowing is the
    # one failure that makes a template useless on the device: the last section
    # is simply not there, and it looks like a design choice rather than a bug.
    blocks = spec.get("blocks", [])
    fixed = sum(natural_height(b, cfg) for b in blocks if not b.get("fill"))
    fixed += cfg["gap"] * max(len(blocks) - 1, 0)
    n_fill = sum(1 for b in blocks if b.get("fill"))
    need = fixed + n_fill * cfg["line_gap"]     # a filler needs one line minimum
    if need > avail + 0.5:
        sys.exit(
            f"Template does not fit the page.\n"
            f"  content needs {need:.0f} pt, the page body is {avail:.0f} pt "
            f"({PAGE_H:g} pt minus margins).\n"
            f"  Over by {need - avail:.0f} pt — about "
            f"{(need - avail) / cfg['line_gap']:.1f} writing lines.\n"
            f"Remove lines, drop a section, or lower line_gap."
        )

    for i in range(n_pages):
        page = doc.new_page(width=PAGE_W, height=PAGE_H)
        cv = PdfCanvas(page, cfg)
        layout(cv, spec.get("blocks", []), x, y, w, avail, cfg)
        if spec.get("page_numbers") and n_pages > 1:
            page.insert_text((PAGE_W - margin_right - 14, PAGE_H - 14),
                             f"{i + 1}", fontname="Helvetica", fontsize=7,
                             color=INK_RULE)

    doc.set_metadata({"title": spec.get("title", out_path.stem),
                      "producer": "remarkable skill / make_template.py"})
    doc.save(out_path, garbage=4, deflate=True)

    if preview:
        pg = doc.load_page(0)
        pg.get_pixmap(matrix=pymupdf.Matrix(2, 2)).save(preview)

    # Assets for installing this as a real on-device template. A template is a
    # single page; the PDF's page count is irrelevant to it.
    if png or svg:
        px_w, px_h = DEVICE_PX[device]
        pg = doc.load_page(0)
        if png:
            # Scale each axis independently. The page is 445x594 (ratio 0.7492)
            # but the panel is 1404x1872 (exactly 0.7500) — close, but a uniform
            # zoom lands 3 px tall, and the device wants the exact panel size.
            # The 0.11% anisotropy is invisible; a wrong-sized template is not.
            pix = pg.get_pixmap(matrix=pymupdf.Matrix(px_w / PAGE_W, px_h / PAGE_H),
                                colorspace=pymupdf.csGRAY, alpha=False)
            if (pix.width, pix.height) != (px_w, px_h):
                sys.exit(f"Template PNG came out {pix.width}x{pix.height}, "
                         f"expected {px_w}x{px_h}. Refusing to write it.")
            pix.save(png)
        if svg:
            Path(svg).write_text(pg.get_svg_image(), encoding="utf-8")

    # Native .template: the same layout, emitted as reMarkable's own vector DSL.
    if template:
        tcv = TemplateCanvas(cfg)
        layout(tcv, spec.get("blocks", []), x, y, w, avail, cfg)
        svg_icon = icon_svg(spec, cfg, margin_left, margin_right)
        doc_json = tcv.document(spec.get("title", Path(template).stem),
                                spec.get("category", "Custom"),
                                icon=svg_icon,
                                labels=spec.get("labels"))
        Path(template).write_text(json.dumps(doc_json, indent=4, ensure_ascii=False),
                                  encoding="utf-8")
        # The picker thumbnail is the same SVG, unencoded, next to the entry.
        Path(template).with_suffix(".icon.svg").write_text(svg_icon, encoding="utf-8")

    doc.close()
    return n_pages


def icon_sheet(out_path, cols=6, cell=76.0, pad=20.0, label=13.0):
    """Every icon on one page, captioned. Both a picker and a regression test —
    a broken arc is obvious here and invisible in a spec file."""
    names = rm_icons.names()
    rows = -(-len(names) // cols)
    doc = pymupdf.open()
    page = doc.new_page(width=cols * cell + 2 * pad,
                        height=rows * (cell + label) + 2 * pad)
    cv = PdfCanvas(page, dict(DEFAULTS))
    for i, name in enumerate(names):
        cx = pad + (i % cols) * cell
        cy = pad + (i // cols) * (cell + label)
        rm_icons.draw(cv, name, cx + cell * 0.11, cy, cell * 0.78)
        tw = pymupdf.get_text_length(name, "Helvetica", 6.5)
        cv.text(cx + (cell - tw) / 2, cy + cell + 8, name, 6.5, ink=INK_HEAD)
    if str(out_path).lower().endswith(".png"):
        page.get_pixmap(matrix=pymupdf.Matrix(2, 2)).save(out_path)
    else:
        doc.save(out_path)
    doc.close()
    return len(names)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", type=Path, nargs="?", help="template JSON")
    ap.add_argument("-o", "--out", type=Path)
    ap.add_argument("--title", help="override the spec's title — for a cover, "
                                    "this is the name on the front and the "
                                    "name the template installs under")
    ap.add_argument("--icons", help="comma-separated icon names for a cover "
                                    "block; the first one is the large one")
    ap.add_argument("--emoji", help="emoji for a cover block, e.g. --emoji "
                                    "'💡📊🐛'. Takes precedence over --icons")
    ap.add_argument("--emoji-style", choices=("solid", "outline"),
                    help="filled silhouettes (default) or hollow line art")
    ap.add_argument("--list-icons", action="store_true",
                    help="print the available cover icons and exit")
    ap.add_argument("--icon-sheet", type=Path, metavar="OUT.pdf",
                    help="draw every cover icon on one captioned page and exit")
    ap.add_argument("--pages", type=int, help="override the spec's page count")
    ap.add_argument("--preview", type=Path, help="also write a 2x PNG of page 1, to look at")
    ap.add_argument("--png", type=Path,
                    help="device-resolution greyscale PNG of page 1, for installing as a real template")
    ap.add_argument("--svg", type=Path,
                    help="SVG of page 1, used by software 3.x for smooth zoom")
    ap.add_argument("--device", choices=sorted(DEVICE_PX), default="rm2",
                    help="panel to size --png for (default: rm2)")
    ap.add_argument("--template", type=Path,
                    help="emit reMarkable's native .template DSL (software 3.20+), "
                         "for a real installed template with unlimited pages")
    args = ap.parse_args()

    if args.list_icons:
        print("\n".join(rm_icons.names()))
        return 0
    if args.icon_sheet:
        args.icon_sheet.parent.mkdir(parents=True, exist_ok=True)
        n = icon_sheet(args.icon_sheet)
        print(f"{args.icon_sheet}  {n} icons", file=sys.stderr)
        return 0
    if not args.spec or not args.out:
        ap.error("spec and --out are required (except with --list-icons)")

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    if args.title:
        spec["title"] = args.title
    covers = [b for b in spec.get("blocks", []) if b.get("type") == "cover"]
    if args.icons or args.emoji or args.emoji_style:
        if not covers:
            ap.error("--icons/--emoji only apply to a spec with a cover block")
        for b in covers:
            if args.icons:
                b["icons"] = [s.strip() for s in args.icons.split(",") if s.strip()]
            if args.emoji:
                b["emoji"] = args.emoji
            if args.emoji_style:
                b["emoji_style"] = args.emoji_style

    args.out.parent.mkdir(parents=True, exist_ok=True)
    for p in (args.preview, args.png, args.svg, args.template):
        if p:
            p.parent.mkdir(parents=True, exist_ok=True)
    n = build(spec, args.out, args.pages, args.preview,
              args.png, args.svg, args.device, args.template)

    print(f"{args.out}  {n} page(s)  {PAGE_W:g} x {PAGE_H:g} pt", file=sys.stderr)
    for p, what in ((args.preview, "preview"), (args.png, "template PNG"),
                    (args.svg, "template SVG"), (args.template, "native .template")):
        if p:
            print(f"{p}  ({what})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
