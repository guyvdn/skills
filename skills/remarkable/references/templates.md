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

## Two ways to use one: PDF, or a real template

|  | Imported PDF | Installed template |
|---|---|---|
| Pages | Fixed — you generate 40 and that is what you get | Unlimited; every new page uses it |
| Pick per page | No, it is a document | Yes, from the template picker |
| Notebook default | No | Yes |
| Install | Supported, no device changes | SSH, unsupported by reMarkable |
| Firmware update | Survives | **Wiped — needs re-linking** |
| Reverse it | Delete the document | `-Uninstall` |

Start with the PDF. Move to a real template when you know the design is right
and you want it as a notebook default.

### As a PDF

- **USB web interface** — `Add-RemarkableFile.ps1`, or drag it onto
  `http://10.11.99.1` in a browser.
- **The desktop or mobile app**, if cloud sync is on.
- **`rmapi put standup.pdf /Templates`** over the cloud.

Note the tablet keeps the `.pdf` extension in the visible name, unlike a notebook.

### As a real template

A template is a **single-page image at exact panel resolution**, not a PDF:

```bash
python make_template.py templates/standup.json -o standup.pdf \
       --png Standup.png --svg Standup.svg --device rm2
```

`--device rm2` gives 1404 x 1872, `pp` gives 1620 x 2160. Both must be **exact**
— the device is strict. Watch for this trap: the page is 445 x 594 (ratio
0.7492) but the panel is exactly 0.7500, so a uniform zoom lands three pixels
tall. The generator scales each axis independently and refuses to write a
wrongly-sized PNG. The 0.11% anisotropy is invisible.

The SVG is optional and is what software 3.x uses for smooth zoom.

```powershell
.\Install-RemarkableTemplate.ps1 -Png .\Standup.png -Svg .\Standup.svg `
    -Name 'Standup' -Password '<from the device>'
```

The password is in **Settings ▸ General ▸ Help ▸ About ▸ Copyrights and
licenses**, at the bottom with the IP. **It changes on every firmware update.**

#### Why it survives updates, and what it does not

`/usr/share/remarkable/templates/` is part of the system image, so a firmware
update **replaces the whole directory** — your PNGs and the `templates.json`
entries both vanish. The installer therefore keeps the real files under
`/home/root/.local/share/remarkable/templates/`, which updates leave alone, and
symlinks them into place. After an update:

```powershell
.\Install-RemarkableTemplate.ps1 -Relink        # restores the symlinks
```

then re-run the install for each template to put its `templates.json` entry
back. `templates.json` is backed up to `templates.json.orig` on first install,
so the original is always recoverable.

Also note the SSH host key changes on every update, so the script disables host
key checking — over a USB cable to a link-local address that is a reasonable
trade, but it is worth knowing it is doing it.

#### What this does and does not touch

It writes to the template directory and restarts `xochitl` (the UI). It does
**not** touch your notebooks, and `-Uninstall` reverses it. It is unsupported by
reMarkable, so treat it as deliberate rather than routine — and take it as given
that a botched `templates.json` breaks the template picker until restored from
the backup.
