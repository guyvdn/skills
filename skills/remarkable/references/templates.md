# Making template PDFs for the tablet

## The page size, and why it is that number

```
445 x 594 pt   =   157.0 x 209.5 mm   =   ratio 0.7492 (3:4)
```

**This is measured, not derived.** Export any notebook from the device and every
normal page is exactly `445 x 594` — 84 of 84 in one real folder. Do not compute
it from the panel spec (1404 x 1872 px at 226 dpi gives 447.3 x 596.4 pt, which
is close but not what the firmware uses), and do not use A4 or Letter.

`make_template.py` hard-codes this. If reMarkable ever changes it, re-measure
with:

```python
import pymupdf; print(pymupdf.open("exported.pdf")[0].rect)
```

### Why the ratio is the part that matters

The device scales an imported PDF to fit the screen and centres it. Both the
reMarkable 2 (1404 x 1872) and the Paper Pro (1620 x 2160) are **3:4**, so a
3:4 page fills the screen edge to edge on either. Give it A4 (0.707) and you get
grey bands top and bottom and a smaller writing area; give it Letter (0.773) and
you lose width. Nothing breaks — it just wastes screen and the lines no longer
line up with the bezel.

Physically the Paper Pro is a larger panel, so the same PDF gives you bigger
lines rather than more of them. A line gap tuned on one is comfortable on both.

## Design rules for e-ink

- **Vector only.** No images. It stays crisp at any zoom and keeps the file
  tiny — a 40-page template is a few kB.
- **Base-14 fonts only** (Helvetica, Times, Courier). Nothing to embed, nothing
  that can fail to render. `make_template.py` uses Helvetica.
- **Grey levels.** The rM2 panel is 16-level greyscale. Rules at ~0.68 grey are
  visible in daylight without competing with your ink; below ~0.80 they start to
  disappear, above ~0.55 they look like part of the writing. Headings at ~0.28.
- **Line gap 24–28 pt** (8.5–10 mm). 26 is the default and suits most adult
  handwriting; drop to 22 only if you write small.
- **Margins.** 30 pt sides is enough to clear the bezel and leave room for the
  collapsed toolbar without the content feeling cramped.
- **Page count.** Generate a stack — 40 standups, 52 weeks — so you tick through
  the notebook rather than re-importing. `--pages` overrides the spec.

## The spec format

A JSON file: page-level settings plus a list of blocks laid out top to bottom.

```json
{
  "title": "Standup",
  "pages": 40,
  "line_gap": 26,
  "page_numbers": true,
  "blocks": [ ... ]
}
```

Page-level keys: `pages`, `line_gap`, `margin_x`, `margin_top`, `margin_bottom`,
`gap` (space between blocks), `rule_width`, `head_size`, `page_numbers`.

### Blocks

| type | what it draws |
|---|---|
| `header` | Title on the left, labelled fill-in fields on the right, heavy rule under |
| `section` | An optionally-titled block in one of the styles below |
| `row` | Side-by-side columns, each holding its own blocks |
| `rule` | A single horizontal divider |
| `spacer` | Vertical space (`size`) |

`section` styles: `lines` (writing rules), `checks` (checkbox + rule),
`dots` (dot grid, `step`), `grid` (squared, `step`), `box` (a bordered area),
`blank` (heading only).

### Sizing

- A block takes its natural height: `lines * line_gap` plus a heading.
- `"height": N` pins it.
- `"fill": true` makes it share whatever is left on the page. Use it for the
  block that should soak up the remainder — usually Notes or To do.
- Inside a `row`, `"width"` is a relative weight (`0.52` / `0.48`).

### Example

```json
{
  "type": "row",
  "fill": true,
  "columns": [
    { "width": 0.52, "blocks": [
        { "type": "section", "title": "To do", "style": "checks", "fill": true } ] },
    { "width": 0.48, "blocks": [
        { "type": "section", "title": "Notes", "style": "dots", "fill": true } ] }
  ]
}
```

## It refuses to overflow

If the blocks need more room than the page body, the script **exits with an
error naming the overage** rather than drawing past the bottom edge:

```
Template does not fit the page.
  content needs 553 pt, the page body is 538 pt (594 pt minus margins).
  Over by 15 pt — about 0.6 writing lines.
```

This is deliberate. A silently clipped template looks like a design choice on
the device — the last section is simply absent — and you only notice in the
middle of the meeting it was made for. The shipped `weekly.json` was caught by
this guard during development.

## Checking one before you commit to it

```bash
python make_template.py templates/standup.json -o standup.pdf --pages 1 --preview standup.png
```

Then look at the PNG. Worth checking: nothing is clipped at the bottom, the
first writing slot is the same height as the rest, and the rules are dark enough
to see but light enough to write over.

## Getting it onto the tablet

Any of:

- **USB web interface** — drag the PDF onto `http://10.11.99.1` in a browser, or
  `POST` it to `http://10.11.99.1/upload` as multipart `file`. It lands in the
  folder most recently listed.
- **The desktop or mobile app**, if cloud sync is on.
- **`rmapi put standup.pdf /Templates`** over the cloud.

Imported PDFs live alongside notebooks and annotate the same way. They are *not*
the same thing as the device's built-in templates (the ones under "new notebook
→ template"), which live in the firmware and need a modified device to extend —
a PDF is the supported route and survives every update.
