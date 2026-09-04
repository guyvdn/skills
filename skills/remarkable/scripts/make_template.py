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
import json
import sys
from pathlib import Path

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

# --- ink levels --------------------------------------------------------------
# The rM2 panel is 16-level greyscale. Below roughly 0.80 grey a rule stops
# being visible in daylight; above 0.55 it competes with your handwriting.
INK_TEXT = (0.10, 0.10, 0.10)
INK_HEAD = (0.28, 0.28, 0.28)   # section headings
INK_RULE = (0.68, 0.68, 0.68)   # writing lines
INK_EDGE = (0.52, 0.52, 0.52)   # box borders, field underlines
INK_DOT = (0.76, 0.76, 0.76)

# Drop below a section heading before the first writing slot begins. Tuned so
# that first slot is the same height as every slot after it — you write *above*
# a rule, so an over-generous drop makes the first line sit oddly low.
HEAD_DROP = 4.0

DEFAULTS = {
    "margin_x": 30.0,
    "margin_top": 30.0,
    "margin_bottom": 26.0,
    "line_gap": 26.0,      # ~9.2 mm — comfortable adult handwriting
    "rule_width": 0.6,
    "head_size": 8.5,
    "gap": 14.0,           # vertical space between blocks
}


class Canvas:
    def __init__(self, page, cfg):
        self.p = page
        self.cfg = cfg

    def rule(self, x0, y, x1, color=INK_RULE, width=None):
        self.p.draw_line((x0, y), (x1, y),
                         color=color, width=width or self.cfg["rule_width"])

    def heading(self, x, y, text):
        """Small-caps-ish section heading with a rule under it."""
        self.p.insert_text((x, y), text.upper(), fontname="Helvetica-Bold",
                           fontsize=self.cfg["head_size"], color=INK_HEAD)
        return y + 5.0

    def label(self, x, y, text, size=8.0):
        self.p.insert_text((x, y), text, fontname="Helvetica",
                           fontsize=size, color=INK_HEAD)

    def checkbox(self, x, y, size=9.0):
        r = pymupdf.Rect(x, y - size, x + size, y)
        self.p.draw_rect(r, color=INK_EDGE, width=0.7)


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
        cv.p.draw_rect(pymupdf.Rect(x, y, x + w, top + h),
                       color=INK_EDGE, width=0.7)
        return

    if style == "dots":
        step = float(spec.get("step", 16.0))
        yy = y + step / 2
        while yy < top + h - 2:
            xx = x + step / 2
            while xx < x + w - 2:
                cv.p.draw_circle((xx, yy), 0.55, color=INK_DOT,
                                 fill=INK_DOT, width=0)
                xx += step
            yy += step
        return

    if style == "grid":
        step = float(spec.get("step", 18.0))
        yy = y
        while yy <= top + h:
            cv.rule(x, yy, x + w)
            yy += step
        xx = x
        while xx <= x + w:
            cv.p.draw_line((xx, y), (xx, top + h), color=INK_RULE,
                           width=cfg["rule_width"])
            xx += step
        return

    # lines / checks — fill the available height rather than a fixed count
    n = int((top + h - y) // gap)
    if spec.get("lines"):
        n = min(n, int(spec["lines"]))
    for i in range(n):
        ly = y + (i + 1) * gap
        if style == "checks":
            cv.checkbox(x, ly - 3.0)
            cv.rule(x + 15.0, ly, x + w)
        else:
            cv.rule(x, ly, x + w)


def render_header(cv, spec, x, y, w, h, cfg):
    """Title on the left, labelled fill-in fields on the right."""
    title = spec.get("title", "")
    fields = spec.get("fields", [])

    baseline = y + 15.0
    tw = 0.0
    if title:
        size = float(spec.get("size", 15.0))
        cv.p.insert_text((x, baseline), title, fontname="Helvetica-Bold",
                         fontsize=size, color=INK_TEXT)
        tw = pymupdf.get_text_length(title, "Helvetica-Bold", size) + 18.0

    if fields:
        avail = w - tw
        total_flex = sum(float(f.get("flex", 1)) for f in fields)
        fx = x + tw
        for f in fields:
            fw = avail * float(f.get("flex", 1)) / total_flex - 10.0
            cv.label(fx, baseline, f["label"] + " ", size=8.0)
            lw = pymupdf.get_text_length(f["label"] + " ", "Helvetica", 8.0)
            cv.rule(fx + lw, baseline + 2.0, fx + fw, color=INK_EDGE, width=0.7)
            fx += fw + 10.0

    # the heavy rule that separates the header from the body
    cv.rule(x, y + h - 6.0, x + w, color=INK_HEAD, width=1.0)


def render_rule(cv, spec, x, y, w, h, cfg):
    cv.rule(x, y + h / 2, x + w, color=INK_EDGE, width=0.7)


RENDERERS = {
    "header": render_header,
    "section": render_section,
    "rule": render_rule,
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


def build(spec, out_path, pages=None, preview=None):
    cfg = dict(DEFAULTS)
    for k in cfg:
        if k in spec:
            cfg[k] = float(spec[k])

    n_pages = int(pages or spec.get("pages", 1))
    doc = pymupdf.open()

    x = cfg["margin_x"]
    w = PAGE_W - 2 * cfg["margin_x"]
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
        cv = Canvas(page, cfg)
        layout(cv, spec.get("blocks", []), x, y, w, avail, cfg)
        if spec.get("page_numbers") and n_pages > 1:
            page.insert_text((PAGE_W - cfg["margin_x"] - 14, PAGE_H - 14),
                             f"{i + 1}", fontname="Helvetica", fontsize=7,
                             color=INK_RULE)

    doc.set_metadata({"title": spec.get("title", out_path.stem),
                      "producer": "remarkable skill / make_template.py"})
    doc.save(out_path, garbage=4, deflate=True)

    if preview:
        pg = doc.load_page(0)
        pg.get_pixmap(matrix=pymupdf.Matrix(2, 2)).save(preview)
    doc.close()
    return n_pages


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", type=Path, help="template JSON")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--pages", type=int, help="override the spec's page count")
    ap.add_argument("--preview", type=Path, help="also write a PNG of page 1")
    args = ap.parse_args()

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    n = build(spec, args.out, args.pages, args.preview)

    print(f"{args.out}  {n} page(s)  {PAGE_W:g} x {PAGE_H:g} pt", file=sys.stderr)
    if args.preview:
        print(f"{args.preview}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
