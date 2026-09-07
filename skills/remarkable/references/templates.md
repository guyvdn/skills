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
| `cover` | A framed poster page — title banner, icon collage, footer rule. See [covers.md](covers.md) |

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
python make_template.py templates/standup.json -o out/standup.pdf --pages 1 --preview out/standup.png
```

Then look at the PNG. Worth checking: nothing is clipped at the bottom, the
first writing slot is the same height as the rest, and the rules are dark enough
to see but light enough to write over.

## Two ways to use one: PDF, or a real template

|  | Imported PDF | Template (library entry) | Template (legacy) |
|---|---|---|---|
| Pages | Fixed — 40 is 40 | Unlimited | Unlimited |
| Pick per page | No, it is a document | Yes | Yes |
| Notebook default | No | Yes | Yes |
| Install | No device changes | SSH | SSH |
| Firmware update | Survives | **Survives** | Wiped; `-Relink` |
| Syncs to cloud | Yes | Yes | No |
| Reverse it | Delete the document | `-Uninstall` | `-Uninstall` |
| Script | `Add-RemarkableFile.ps1` | `Add-RemarkableCustomTemplate.ps1` | `Install-RemarkableTemplate.ps1` |

Start with the PDF while you are still changing the design — it needs no device
access. Move to a **library-entry template** once it is right. The legacy column
is only for firmware with no `CustomTemplate` support.

### As a PDF

- **USB web interface** — `Add-RemarkableFile.ps1`, or drag it onto
  `http://10.11.99.1` in a browser.
- **The desktop or mobile app**, if cloud sync is on.
- **`rmapi put standup.pdf /Templates`** over the cloud.

Note the tablet keeps the `.pdf` extension in the visible name, unlike a notebook.

### As a real template

**Check the format first — it changed.** Every older guide says a template is a
PNG. On software 3.20+ (verified on build `20260612085811`, reMarkable 2) the
templates directory holds **65 `.template` files and zero PNGs**:

```bash
ssh root@10.11.99.1 'ls /usr/share/remarkable/templates | sed "s/.*\.//" | sort | uniq -c'
#      1 json
#     65 template
```

A `.template` is a small declarative **vector DSL**, not an image — which is why
they are ~1 kB each and stay crisp at any zoom:

```json
{
  "name": "Lines medium", "orientation": "portrait", "formatVersion": 1,
  "constants": [ {"magicOffsetY": 177.8} ],
  "items": [
    { "type": "group",
      "boundingBox": {"x": "templateWidth / 2 - templateHeight / 2",
                      "y": "offsetY", "width": "templateHeight", "height": 78.7},
      "repeat": {"rows": "down"},
      "children": [ {"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]} ] }
  ]
}
```

Three item types: `path` (SVG-ish `M`/`L`/`Z` data), `text` (`text`, `fontSize`,
`position`), and `group` (a `boundingBox` plus `repeat`, which takes
`rows`/`columns` as a count, `"down"`, `"up"`, `"right"` or `"infinite"`).
Paths accept `strokeColor`, `strokeWidth` and `fillColor`. Values may be
expressions over `templateWidth`, `templateHeight`, `parentWidth`,
`paperOriginX` and your own `constants`, including ternaries.

#### The coordinate system

**1 unit = 1 device pixel**: portrait is `templateWidth` 1404, `templateHeight`
1872 on an rM2. That is not documented anywhere; it was derived by measuring
stock templates against notebooks written on them, and it holds three ways:

| Check | DSL | Lands at | Measured |
|---|---|---|---|
| Group x of a portrait lines template | `(1404-1872)/2` = -234 | -74.17 pt | **-74.2 pt** |
| `P US College` repeat height | 62 | 19.65 pt | **19.7 pt** |
| That is also the template in `xochitl.conf` `LastUsedTemplates` | — | — | ✓ |

So **1 pt = 3.1551 units**. Confirmed by installing a generated template on a
device and rendering it — the layout comes out at the intended size and
position. Verify it the same way on new firmware rather than trusting it:
export a notebook, measure the background rules, compare.

#### The parser's rules, and how to see them

**`fontSize` must be a positive integer.** A float makes the device reject the
*entire file*, and the symptom is not an error you can see — the template still
appears in the picker and applies to a page, and renders **completely blank**.
That looks like a layout bug and is not one. Every stock template uses an
integer (24, 25, 32, 72); `make_template.py` rounds. `strokeWidth` is rounded
too, on the same suspicion.

The device tells you exactly what is wrong, if you ask it:

```bash
ssh root@10.11.99.1 'journalctl -u xochitl --no-pager -n 200 | grep -i template'
# failed to parse template file: ".../Standup.template" .
#   Error: "error: 'fontSize' must be a positive value"
```

**Check that log after every install.** It is the only feedback the device
gives; the UI shows a blank page either way.

Also note xochitl scans the staging directory and tries to parse everything in
it, so backups must not live there — the installer keeps them in
`/home/root/rm-template-backups/` instead.

#### Generate and install

```bash
python make_template.py templates/standup.json -o out/standup.pdf --template out/Standup.template
```

```powershell
.\Install-RemarkableTemplate.ps1 -Template .\out\Standup.template -Password '<from the device>'
```

`--png` and `--svg` still exist for older firmware that wants an image; on 3.20+
they are not what the device reads.

The password is in **Settings ▸ General ▸ Help ▸ About ▸ Copyrights and
licenses**, at the bottom with the IP. **It changes on every firmware update.**

#### The device has no scripting languages

`python3`, `jq` and `perl` are all absent — it is busybox with `sh`, `awk` and
`sed`. Any guide that pipes `templates.json` through `python3` on the device
will fail. The installer pulls the file down, edits it here, and copies it back,
which is also far safer than `sed`-ing JSON in place.

#### The supported route: a custom-template library entry

**Use this one.** `Add-RemarkableCustomTemplate.ps1` installs a template the way
reMarkable's own Methods templates install, so it lives in `/home`, survives
firmware updates and syncs to the cloud.

A custom template is a **library entry**, like a notebook — `customtemplate.cpp`
sits under `src/entry/` in xochitl. It is four files in
`/home/root/.local/share/remarkable/xochitl/`, and **no `templates.json`
anywhere**:

```
<uuid>.metadata               {"type": "TemplateType", "visibleName": "Standup",
                               "source": "com.remarkable.methods", ...}
<uuid>.content                {}
<uuid>.template               the DSL, plus base64 iconData
<uuid>.thumbnails/1-0-1.svg   the same 150x200 icon, unencoded
```

`iconData` is a base64 150x200 SVG shown in the picker — a *schematic* of the
layout (outlined regions, no text), not a rendering of the page.
`make_template.py --template` generates it and writes the matching
`.icon.svg` beside the template; the installer picks that up automatically.

This schema was read off a real Methods template rather than guessed. If you
need to re-derive it on newer firmware, install one template from
<https://methods.remarkable.com> through the app and read the entry it creates:

```bash
ssh root@10.11.99.1 'grep -l TemplateType /home/root/.local/share/remarkable/xochitl/*.metadata'
```

```powershell
.\Add-RemarkableCustomTemplate.ps1 -Template .\out\Standup.template -Password '<from the device>'
.\Add-RemarkableCustomTemplate.ps1 -List -Password '<...>'
.\Add-RemarkableCustomTemplate.ps1 -Name Standup -Uninstall -Password '<...>'
```

#### The legacy route, for reference

Newer firmware has a **first-class custom-template system**, and templates from
<https://methods.remarkable.com> installed through the app use it. Evidence on
the device:

```bash
strings /usr/bin/xochitl | grep -i customtemplate
#   src/entry/src/customtemplate.cpp
#   addCustomTemplate / removeCustomTemplate / updateCustomTemplate
#   customTemplateId / customTemplateIds
strings /usr/bin/xochitl | grep '/templates/'
#   {}/../templates/custom/
#   {}/../templates/import/
```

`customtemplate.cpp` sits under `src/entry/` — the same place as notebooks and
PDFs — so **a custom template is a library entry**, not a file dropped into a
system directory. It lives under `/home/root/.local/share/remarkable/`, which is
why it survives updates and syncs to the cloud. The device also keeps its own
manifest at `templates/import/templates.json`.

`Install-RemarkableTemplate.ps1` writes into `/usr/share/remarkable/templates/`
and edits its `templates.json`. That is what every older guide describes, and it
works — but `/usr/share` is part of the system image, so a firmware update wipes
it. Reach for it only on firmware with no `CustomTemplate` support.

#### Why the legacy route does not survive updates

`/usr/share/remarkable/templates/` is part of the system image, so a firmware
update **replaces the whole directory** — your template files and the
`templates.json` entries both vanish. The installer therefore keeps the real
files under `/home/root/.local/share/remarkable/templates/custom/`, which
updates leave alone, and symlinks them into place. After an update:

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
