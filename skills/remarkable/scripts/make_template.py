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

    def dots(self, x, y, w, h, step):
        yy = y + step / 2
        while yy < y + h - 2:
            xx = x + step / 2
            while xx < x + w - 2:
                self.p.draw_circle((xx, yy), 0.55, color=INK_DOT,
                                   fill=INK_DOT, width=0)
                xx += step
            yy += step


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
            item["strokeWidth"] = round(width * UNITS_PER_PT, 2)
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
        self.items.append({
            "type": "text", "text": s,
            "fontSize": round(size * UNITS_PER_PT, 1),
            "position": {"x": self.u(x), "y": self.u(y)},
        })

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
                "strokeWidth": d,
                "data": ["M", 0, 0, "L", d, 0, "L", d, d, "L", 0, d, "Z"],
            }],
        })

    def document(self, name, category, orientation="portrait"):
        return {
            "name": name,
            "author": "make_template.py",
            "templateVersion": "1.0.0",
            "formatVersion": 1,
            "categories": [category],
            "orientation": orientation,
            "items": self.items,
        }


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


def build(spec, out_path, pages=None, preview=None,
          png=None, svg=None, device="rm2", template=None):
    cfg = dict(DEFAULTS)
    for k in cfg:
        if k in spec and k not in ("toolbar", "margin_left", "margin_right"):
            cfg[k] = float(spec[k])

    margin_left, margin_right = resolve_margins(cfg, spec)

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
        doc_json = tcv.document(spec.get("title", Path(template).stem),
                                spec.get("category", "Custom"))
        Path(template).write_text(json.dumps(doc_json, indent=4, ensure_ascii=False),
                                  encoding="utf-8")

    doc.close()
    return n_pages


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", type=Path, help="template JSON")
    ap.add_argument("-o", "--out", type=Path, required=True)
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

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
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
