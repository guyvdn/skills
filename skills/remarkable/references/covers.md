# Cover pages

A notebook's first page is its thumbnail in the library. A ruled page makes every
notebook look like every other notebook; a bold drawing makes the right one findable
at a glance. That is the whole point of this — it is a **navigation** feature, not
decoration, and every design decision below follows from the thumbnail being about
**20 mm wide**.

```bash
python skills/remarkable/scripts/make_template.py \
    skills/remarkable/templates/cover.json -o dev-leads.pdf \
    --title "Dev leads" \
    --icons person,code-window,lightbulb,bar-chart,arrow-up,gear,laptop \
    --template "Dev leads.template" --preview cover.png
```

That is one spec file for every cover you will ever make. Do not copy `cover.json`
per notebook — override `--title` and `--icons` instead.

## What it draws

```
┌──────────────────────────┐
│      DEV LEADS           │  banner: grey band, title as filled outlines
├──────────────────────────┤
│   ▫    ⬤ hero    ▫       │  collage: first icon large in the centre,
│   ▫              ▫       │  the rest in the corners, then the sides
│   ▫              ▫       │
├──────────────────────────┤
│   ─────────────────      │  footer: a rule to write a date or a period on
└──────────────────────────┘
```

- **The first icon in the list is the hero** — large, centred. Pick the one that says
  what the notebook is; the rest are context.
- Satellites fill **corners first**, then the sides. Three or four icons therefore
  spread out instead of lining up like a toolbar.
- Past eight satellites the extras are dropped, with a note on stderr.

## The icons

`--list-icons` prints the names. `--icon-sheet sheet.pdf` draws all of them on one
captioned page — use that to choose, and **use it as the regression test after
editing `rm_icons.py`**. Four icons shipped visibly broken in the first draft and the
contact sheet is what caught all four; a spec file never would have.

Adding one is a function in `rm_icons.py` with an `@icon("name")` decorator, drawing
in a **unit box**: `0..1` left to right and top to bottom, same direction as the page.
Everything goes through `IconPen`, so an icon never knows whether it is ending up in a
PDF or in the device's DSL.

Two conventions that will trip you up:

- **Angles are counter-clockwise with 0 at 3 o'clock, so 90 is the top** — even though
  `v` grows downwards. `arc_pts(cx, cy, r, r, 210, -30)` sweeps over the crown;
  `210, 330` draws the *bottom* instead. That bug shipped a lightbulb that looked
  like a tulip.
- **`rrect_pts` walks clockwise in four seven-point corners**, TL, TR, BR, BL. To hang
  a speech-bubble tail off the bottom edge you splice it in after index 20; appending
  it at the end draws a line back across the bubble.

For a silhouette made of overlapping circles — a cloud — use `lobes()`, which solves
for the real circle-circle intersections. Guessing the hand-over angles by eye leaves
a notch or a spike, which is exactly what the first cloud did twice.

## Why the title is drawn as shapes, not text

`rm_glyphs.outlines()` renders the title in Helvetica-Bold and hands back **filled
glyph outlines**, and the cover draws those. It looks like a heavier route than a
`text` item, and it is the safer one:

- The template DSL has **no font selection and no bold**. A `text` item gets whatever
  face the firmware picks, at whatever weight — so the PDF preview and the installed
  template would not match.
- `fontSize` is the field that already cost this skill an afternoon: a non-integer
  makes the device reject the entire file and render the template **blank**, with no
  error in the UI. A cover with no text items cannot hit that at all — check with
  `grep '"type": "text"' Cover.template` and expect nothing.

The counters — the hole in a D — are separate subpaths wound the other way, so the
whole set is filled as **one shape with an even-odd rule**. Filled one at a time they
come out solid.

The title auto-shrinks to fit the banner, so a long name silently gets smaller rather
than overflowing. Titles of one or two short words read best; `Dev leads` is fine,
`Q3 platform migration steering` is not.

## Installing it

A cover is a **template**, so it goes on with the normal supported route:

```powershell
powershell -File skills/remarkable/scripts/Add-RemarkableCustomTemplate.ps1 `
    -Template '.\Dev leads.template' -Password '<from the device>'
```

Then on the tablet: open the notebook, **page 1**, template picker, pick it. Set it as
the notebook's default only if you want the artwork on every page, which you almost
certainly do not.

The picker fills up with one entry per notebook, so give them a shared prefix or put
them in their own category — `cover.json` sets `"category": "Covers"`.

You cannot get a cover into a notebook any other way. An imported PDF is its own
document and cannot be merged into an existing notebook, so the PDF output here is for
previewing the design, not for shipping it.

## Numbers worth knowing

| | |
|---|---|
| Cover template file size | ~78 kB, ~40 path items, ~1000 vertices |
| Stock reMarkable template | ~1 kB |
| Text items in a cover | **zero** — that is the point |

78 kB is nothing on the device, but it is two orders of magnitude past a stock
template, so do not be alarmed by it and do not conclude something has gone wrong.
