---
name: remarkable
description: 'Read, transcribe and summarize handwritten notebooks from a reMarkable tablet. Use when the user asks to get at their reMarkable notes, list what is on the tablet, "what did I write in <notebook>", transcribe or OCR handwriting, summarize a notebook, pull out action items or decisions from handwritten meeting notes, search across notebooks, or export a notebook to PDF/Markdown. Covers both transports (the USB web interface at 10.11.99.1 and the reMarkable cloud via rmapi), rasterising the PDF for vision OCR, and the transcription quality rules. Also use when the tablet is plugged in but unreachable.'
version: 1.0.0
compatibility: 'Windows, PowerShell 5.1+ (7+ preferred, for -NoProxy). USB transport needs reMarkable software 3.x with the USB web interface enabled; .rmdoc export needs 3.9+. Cloud transport needs Go and a reMarkable Connect subscription. Page rendering needs Python 3.9+ with pymupdf.'
---

# reMarkable notebooks: fetch, transcribe, summarize

Handwritten pages are not text anywhere in the pipeline. The tablet stores strokes,
exports strokes, and the PDF contains strokes. **The OCR step is your own vision** —
you read rendered page images. There is no OCR binary in this skill and none is wanted:
handwriting is exactly the case where a general vision model beats Tesseract and friends.

The pipeline:

```
tablet ──► PDF ──► per-page PNG ──► you read them ──► transcript.md + summary.md
        (1)     (2)              (3)                (4)
```

## 1. Get the document list

```powershell
powershell -File skills/remarkable/scripts/Get-RemarkableDocs.ps1
powershell -File skills/remarkable/scripts/Get-RemarkableDocs.ps1 -Match 'sprint' -DocumentsOnly -Json
```

`-Transport auto` (default) tries the USB web interface first, then the cloud.
**Prefer USB and say so when it is not available**: over USB the *tablet* renders the
PDF, so pens, colours, highlighters, template backgrounds and annotations on imported
PDFs all come out exactly as they look on the device. rmapi rasterises the strokes
itself and the result is legible but noticeably less faithful. See
[references/transports.md](references/transports.md).

If nothing is reachable, work through
[references/troubleshooting.md](references/troubleshooting.md) before falling back —
"unreachable" is usually routing or a settings toggle, not a broken transport.

## 2. Export the notebook

```powershell
# one notebook
powershell -File skills/remarkable/scripts/Export-RemarkableDoc.ps1 `
    -Name 'Architecture notes' -OutFile out/architecture/source.pdf

# a whole folder — one bad notebook does not abandon the rest
powershell -File skills/remarkable/scripts/Export-RemarkableDoc.ps1 `
    -Folder 'Archive/Project X' -OutDir out/_source -SkipExisting
```

`-Name` matches the full path first, then falls back to a substring match, and
**refuses ambiguity** rather than guessing which notebook the user meant. Pass `-Id`
(from step 1) when a name is genuinely duplicated across folders.

`-Folder` flattens the tree below that folder into `-OutDir`, sanitising each title
into a legal filename. `-SkipExisting` makes it resumable.

On-device rendering of a 100-page notebook takes minutes. The default timeout is 600s;
do not shorten it and then report a timeout as a failure.

## 3. Rasterise to pages

```bash
python skills/remarkable/scripts/pdf_to_pages.py out/architecture/source.pdf \
    --out out/architecture/pages --dpi 150
```

Writes `page-001.png`, … and `manifest.json`. **Read the manifest first.** Every page
carries a `text` field and a `has_text_layer` flag:

- `has_text_layer: true` — the page has a real text layer (Type Folio typing, or the
  body text of an imported PDF the user annotated). **Use that text verbatim.** Only
  look at the image for handwritten margin notes and diagrams on top of it.
- `has_text_layer: false` — handwriting. Read the PNG.

This saves both money and mistakes: never re-transcribe by eye what is already text.

Cost is real and scales with pixel area — doubling `--dpi` quadruples the tokens per
page. Defaults are `--dpi 150` (≈2–3k tokens/page) and a 60-page ceiling.
For a first pass on a long notebook, `--dpi 110 --gray` is a third of the cost and
usually still legible; re-render only the pages that were not.

### Extended pages — the trap that looks like bad handwriting

reMarkable's **extended page** keeps growing downwards as you write, so a single
page can be **ten or more times taller than it is wide**. Scale one of those to fit a
fixed box and the width collapses to a couple of hundred pixels: the render comes
out as an unreadable sliver, and it reads as illegible handwriting rather than as a
rendering mistake. In one real folder, **ten of sixteen** pages in a notebook were
extended pages.

`pdf_to_pages.py` handles this: it caps on **width**, not the long edge, and any page
past a 2.2 aspect ratio is sliced into overlapping horizontal strips
(`page-007-01.png`, `-02`, …). The manifest marks those pages `extended_page: true`
and lists every strip under `images`. **Read all the strips of a page in order** —
the overlap exists so a line cut by a slice boundary is whole in the next one.

The console output names them, so watch for it:

```
page   6/16  1237x1669  [extended page, 7 strips, ratio 7.8]
```

`--no-slice` renders such a page whole, which is almost never what you want.

### Landscape pages

A page written sideways exports rotated. Re-render just that page with
`page.set_rotation(90)` (or 270) before reading rather than trying to read it
turned — a rotated read is noticeably less accurate.

## 4. Read the pages

Read the PNGs **in page order** and in batches of about 5–10. Batching matters:
handwriting is far easier to read once you have seen a few pages of the same hand, and
a term that is illegible on page 9 is often written clearly on page 3.

The transcription rules are not optional — they are what makes the output trustworthy.
Read [references/reading-pages.md](references/reading-pages.md) before the first batch.
The short version:

- **Never invent text.** Unreadable words are `[illegible]`, uncertain ones are
  `[best guess?]`. A confident wrong transcription of someone's own notes is worse
  than a gap, because they cannot tell it is wrong.
- Sketches, diagrams, tables and arrows get **described**, not transcribed.
- Preserve structure the user drew: boxes, indentation, arrows between ideas,
  circled or starred items, strikethroughs (they mean "dropped", keep them marked).
- Keep the original language. Dutch notes stay Dutch in the transcript; put the
  summary in the language the user asked in.

## 5. Write the output

Default layout, under `remarkable-out/<notebook-name>/` unless the user names a place:

```
source.pdf        the export, kept so nothing has to be re-fetched
pages/            PNGs + manifest.json
transcript.md     page by page, with "## Page N" headings
summary.md        the deliverable
```

`summary.md` structure — drop sections that have no content rather than padding them:

- **What this notebook is** — one or two sentences, plus the date range if datable.
- **Themes** — the 3–6 threads the notebook actually returns to, each with page refs.
- **Decisions** — what was settled, with the page it was settled on.
- **Actions / TODOs** — verbatim where possible, with page refs, flagged done if
  struck through or ticked.
- **Open questions** — things written with a question mark and never answered later
  in the notebook. These are usually the most useful output and the easiest to miss.
- **Names, dates, figures** — anything a search would need.
- **Not readable** — every `[illegible]` with its page number, so the user knows
  exactly what to go and look at themselves.

Cite page numbers throughout (`p.12`). They are how the user gets back to the ink.

## Searching across notebooks

There is no server-side full-text search over handwriting — the tablet's
`/search/{keyword}` endpoint is incomplete and does not cover ink. To answer
"which notebook did I write about X in", export and transcribe the plausible
candidates (filter with `-Match` on names first, and use the modified dates), then
search the transcripts. Say plainly that this is what you are doing and roughly how
many pages it will read, before doing it for a whole tablet.

## Making template PDFs

The other direction: generate a ruled page — standup, meeting notes, weekly plan —
sized to the device so it fills the screen instead of sitting in grey bands.

```bash
python skills/remarkable/scripts/make_template.py \
    skills/remarkable/templates/standup.json -o standup.pdf --pages 40 --preview p1.png
```

Ships with `standup.json`, `meeting.json`, `weekly.json`. Write a new one by
copying a spec — blocks are `header`, `section` (styles `lines` / `checks` /
`dots` / `grid` / `box`), `row`, `rule`, `spacer`.

**The page is `445 x 594 pt`, measured from the tablet's own exports** — not
computed from the panel spec, and not A4. It is 3:4, which is the ratio of both
the rM2 and the Paper Pro, so it fills either screen edge to edge.

**The pinned toolbar floats over the page**, so the margin on its side must clear
it — about 130 px, which is 41 pt on this page. Specs say `"toolbar": "left"`
(the default), `"right"`, or `"none"`, and the generator widens the correct
margin. Getting this wrong puts your first words under the toolbar.

Two ways to use the result, and they are different things:

- **As a PDF** — supported, no device changes, but a fixed page count.
  `Add-RemarkableFile.ps1` puts it on the tablet.
- **As a real template** — unlimited pages, pickable per page, settable as a
  notebook default. `--template` emits reMarkable's own vector DSL and
  `Install-RemarkableTemplate.ps1` installs it over SSH.

  Two installers, and the choice matters:

  - `Add-RemarkableCustomTemplate.ps1` — **the supported route.** Installs it as
    a library entry, the same way methods.remarkable.com templates install. Lives
    in `/home`, survives firmware updates, syncs. Use this.
  - `Install-RemarkableTemplate.ps1` — the legacy `/usr/share` + `templates.json`
    route every older guide describes. Works, but a firmware update wipes it.

  See [references/templates.md](references/templates.md) before running either.

The generator **refuses to overflow**: a spec that needs more room than the page
body fails with the overage in points rather than quietly drawing past the bottom,
because a clipped template reads as a design choice on the device rather than a bug.

Always render `--preview` and look at it before shipping a template. Details —
grey levels for e-ink, line gaps and the spec reference — are in
[references/templates.md](references/templates.md).

Put it on the tablet with:

```powershell
powershell -File skills/remarkable/scripts/Add-RemarkableFile.ps1 -Path .\Standup.pdf
powershell -File skills/remarkable/scripts/Add-RemarkableFile.ps1 -Path .\*.pdf -Folder 'Templates'
```

`-WhatIf` dry-runs it. **This is the one thing in the skill that writes to the
device — confirm with the user before running it**, and note the tablet keeps the
`.pdf` extension in the document's visible name, unlike a notebook.

To prove a template actually loaded, export it straight back: if
`/download/<guid>/pdf` returns the right page count and geometry, the device
parsed and rendered it.

## Making a cover page

The first page of a notebook is what the library shows as its thumbnail, so a bold
drawing there is how you find the right notebook without opening three. Same
generator, a `cover` block:

```bash
python skills/remarkable/scripts/make_template.py \
    skills/remarkable/templates/cover.json -o dev-leads.pdf \
    --title "Dev leads" --emoji "👥" \
    --template "Dev leads.template" --preview cover.png
```

A caps title at the top and **one** emoji filling the middle. Nothing else — no frame,
no band, no rules. `cover.json` is the only spec you need; override `--title` and
`--emoji` rather than copying it per notebook.

That austerity is the design, not laziness. The thumbnail is **118 px wide**, and at
that size a frame costs contrast, a grey title band drops the title to black-on-grey,
a stroked emoji collapses into a scribble, and a second emoji halves both. The
silhouette is what finds the notebook; the word only confirms it.

**Pick an emoji with a solid mass.** Ring shapes — compass, gear, target — all
collapse into the same dark donut and stop being distinguishable from each other,
which is the one thing a navigation aid must not do.

Emoji come from the **system emoji font as outlines** — Segoe UI Emoji on Windows,
whose base glyph layer is a clean black silhouette. **Single code points only**: a ZWJ
sequence like the technologist emoji has no single glyph and comes back empty, with a
note on stderr. `--icons` is an older hand-drawn library, kept but not preferred — see
[references/covers.md](references/covers.md).

**Always look at the preview at thumbnail size, not full size**, since that is where
the design either works or does not:

```python
pymupdf.open("dev-leads.pdf")[0].get_pixmap(matrix=pymupdf.Matrix(118/445, 118/445)).save("thumb.png")
```

Install it as a template (`Add-RemarkableCustomTemplate.ps1`), then apply it to page 1
in the picker. **The PDF output is for previewing only** — an imported PDF is its own
document and cannot be merged into an existing notebook, so the template is the only
route that actually gets a cover onto a notebook's first page.

The title is drawn as **filled glyph outlines, not a `text` item**, so it is the same
Helvetica-Bold in the PDF and on the device, and a cover cannot hit the
non-integer-`fontSize` failure that renders a template blank. See
[references/covers.md](references/covers.md) for the drawing conventions before
adding an icon — the angle convention and `rrect_pts` ordering both bite.

## Notes and limits

- The tablet's own **Convert to text** (select strokes → Convert) is excellent but is
  a manual, on-device action. It cannot be scripted, over either transport. When a
  user wants a permanent typed copy of one page, that is the better tool — suggest it.
- `VissibleName` is the tablet's own spelling of the title field. Not a typo to fix.
- The USB web interface is unauthenticated on a link-local network; anything on
  that subnet can read every notebook while it is enabled.
- **Three scripts write to the tablet** — `Add-RemarkableFile.ps1` (uploads a
  document), `Add-RemarkableCustomTemplate.ps1` and `Install-RemarkableTemplate.ps1`
  (install a template over SSH). Everything else is read-only. **Confirm with the
  user before running any of the three.** There is no delete endpoint on the web
  interface — documents have to be removed on the device by hand.
