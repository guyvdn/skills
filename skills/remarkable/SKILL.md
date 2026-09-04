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
    -Folder 'Archive/Gosselin' -OutDir out/_source -SkipExisting
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

## Notes and limits

- The tablet's own **Convert to text** (select strokes → Convert) is excellent but is
  a manual, on-device action. It cannot be scripted, over either transport. When a
  user wants a permanent typed copy of one page, that is the better tool — suggest it.
- `VissibleName` is the tablet's own spelling of the title field. Not a typo to fix.
- The USB web interface is read-mostly and unauthenticated on a link-local network;
  anything on that subnet can read every notebook while it is enabled.
- Nothing here writes to the tablet. Uploads are deliberately out of scope.
