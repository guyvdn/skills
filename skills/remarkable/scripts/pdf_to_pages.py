#!/usr/bin/env python3
"""Split a reMarkable PDF export into per-page PNGs plus any real text layer.

Handwriting in a reMarkable PDF is vector strokes, not text, so it has to be
rasterised before a vision model can read it. Typed content (Type Folio pages,
and the text of an annotated PDF) *is* a real text layer -- this pulls that out
for free so those pages never need to be transcribed by eye.

Output:
    <out>/page-001.png ...
    <out>/manifest.json   -- one entry per page: png path, extracted text,
                             and whether that text is substantial enough to
                             trust over the image.

Usage:
    python pdf_to_pages.py notes.pdf --out ./pages
    python pdf_to_pages.py notes.pdf --out ./pages --pages 3-12 --dpi 200
    python pdf_to_pages.py notes.pdf --out ./pages --gray --dpi 110   # cheap pass
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import pymupdf  # PyMuPDF >= 1.24
except ImportError:  # pragma: no cover - older wheels only expose `fitz`
    try:
        import fitz as pymupdf
    except ImportError:
        sys.exit(
            "PyMuPDF is required to rasterise the PDF.\n"
            "  python -m pip install pymupdf\n"
            "It ships as a self-contained wheel -- no Ghostscript or poppler needed."
        )

# Below this many characters a page's text layer is noise (a stray page number,
# an OCR artefact in an imported PDF) and the image is the real source.
TEXT_LAYER_MIN_CHARS = 40

# Long edge cap. A vision model gains nothing above this and every extra pixel
# is tokens: cost scales with area, so 2x the DPI is 4x the price per page.
MAX_LONG_EDGE_PX = 2000


def parse_page_range(spec: str, page_count: int) -> list[int]:
    """'3', '3-12', '1-5,9,20-' -> zero-based page indices."""
    if not spec:
        return list(range(page_count))

    pages: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, _, hi = part.partition("-")
            start = int(lo) if lo.strip() else 1
            end = int(hi) if hi.strip() else page_count
        else:
            start = end = int(part)
        if start < 1 or end > page_count or start > end:
            sys.exit(f"Page range '{part}' is outside 1-{page_count}.")
        pages.update(range(start - 1, end))
    return sorted(pages)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf", type=Path)
    ap.add_argument("--out", type=Path, required=True, help="output directory (created if missing)")
    ap.add_argument("--pages", default="", help="1-based range, e.g. 3-12 or 1-5,9")
    ap.add_argument("--dpi", type=int, default=150,
                    help="render resolution; 150 reads most handwriting, 200+ for cramped script (default: 150)")
    ap.add_argument("--max-pages", type=int, default=60,
                    help="refuse to render more than this without --force (default: 60)")
    ap.add_argument("--gray", action="store_true",
                    help="grayscale output -- smaller, but loses highlighter and Paper Pro pen colour")
    ap.add_argument("--force", action="store_true", help="ignore --max-pages")
    args = ap.parse_args()

    if not args.pdf.is_file():
        sys.exit(f"No such file: {args.pdf}")

    doc = pymupdf.open(args.pdf)
    page_count = doc.page_count
    wanted = parse_page_range(args.pages, page_count)

    if len(wanted) > args.max_pages and not args.force:
        sys.exit(
            f"{len(wanted)} pages requested, limit is {args.max_pages}.\n"
            f"Rendering every page of a long notebook is slow and expensive to read.\n"
            f"Narrow it with --pages 1-{args.max_pages}, or pass --force."
        )

    args.out.mkdir(parents=True, exist_ok=True)

    colorspace = pymupdf.csGRAY if args.gray else pymupdf.csRGB
    zoom = args.dpi / 72.0
    entries = []

    for idx in wanted:
        page = doc.load_page(idx)

        # Cap the long edge so a big Paper Pro page cannot blow up the token cost.
        rect = page.rect
        effective_zoom = zoom
        long_edge_px = max(rect.width, rect.height) * zoom
        if long_edge_px > MAX_LONG_EDGE_PX:
            effective_zoom = MAX_LONG_EDGE_PX / max(rect.width, rect.height)

        pix = page.get_pixmap(matrix=pymupdf.Matrix(effective_zoom, effective_zoom),
                              colorspace=colorspace, alpha=False)
        png = args.out / f"page-{idx + 1:03d}.png"
        pix.save(png)

        text = page.get_text().strip()
        entries.append({
            "page": idx + 1,
            "png": str(png).replace("\\", "/"),
            "width": pix.width,
            "height": pix.height,
            "text": text,
            # True => trust the text layer; the image is only needed for
            # handwritten margin notes and diagrams.
            "has_text_layer": len(text) >= TEXT_LAYER_MIN_CHARS,
        })
        print(f"page {idx + 1:>3}/{page_count}  {pix.width}x{pix.height}"
              f"{'  [text layer]' if entries[-1]['has_text_layer'] else ''}", file=sys.stderr)

    manifest = {
        "source": str(args.pdf.resolve()).replace("\\", "/"),
        "title": doc.metadata.get("title") or args.pdf.stem,
        "page_count": page_count,
        "rendered": len(entries),
        "dpi": args.dpi,
        "grayscale": bool(args.gray),
        "pages": entries,
    }
    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    doc.close()

    print(f"\n{len(entries)} of {page_count} pages -> {args.out}", file=sys.stderr)
    print(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
