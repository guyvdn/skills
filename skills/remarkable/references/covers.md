# Cover pages

A notebook's first page is its thumbnail in the library. A ruled page makes every
notebook look like every other notebook; a bold cover makes the right one findable at
a glance. This is a **navigation** feature, not decoration, and every decision below
follows from one number: the thumbnail is about **20 mm wide**, which is **118 px**.

```bash
python skills/remarkable/scripts/make_template.py \
    skills/remarkable/templates/cover.json -o dev-leads.pdf \
    --title "Dev leads" --emoji "👥" \
    --template "Dev leads.template" --preview cover.png
```

One spec file for every cover you will ever make. Do not copy `cover.json` per
notebook — override `--title` and `--emoji`.

## The design, and what was cut to get there

```
┌──────────────────────────┐
│      DEV LEADS           │  title: caps, Helvetica-Bold outlines, black
│                          │
│                          │
│          ⬤⬤             │  one emoji, solid, 0.70 of the page width
│                          │
│                          │
└──────────────────────────┘   no frame, no band, no rule, no date line
```

Two marks, pure black on white, clear space between them. Everything else was tried
and removed, each for a measured reason at 118 px:

| Cut | Why |
|---|---|
| Rounded frame | Costs contrast, adds a third thing to parse, invisible at thumbnail size |
| Grey title banner | Drops the title from black-on-white to black-on-grey — measurably weaker |
| Hollow (stroked) emoji | A 4 pt stroke is 1.1 px; the silhouette turns into a grey scribble |
| Rule under the title | Renders as a hard 1 px bar that competes with the artwork and says nothing |
| Footer date rule | Simply invisible |
| Multiple emoji | Four emoji drop to ~40 px each and stop being distinguishable |

**Caps beat sentence case.** All-caps is an even-weight solid block; lowercase
counters and ascenders fill in first as the render shrinks.

**The shape carries the recognition, the word confirms it.** Across thirty-five
notebooks you find the right one by silhouette before you read anything, which is why
the emoji gets 0.70 of the page width and the title is capped rather than maximised.

## Picking the emoji

**Prefer a solid mass.** Ring-shaped glyphs — 🧭 compass, ⚙ gear, 🎯 target — all
collapse into the same dark donut at thumbnail size and become indistinguishable from
each other. That is the exact failure mode for a navigation aid.

Emoji come from the **system emoji font as outlines**. On Windows that is Segoe UI
Emoji (`seguiemj.ttf`), a colour COLR/CPAL font whose *base* glyph layer is a clean
black silhouette; extracting outlines rather than rendering the font normally is what
gets that layer, and it happens to be exactly what a 16-level greyscale panel wants.
The lookup order is `rm_glyphs.EMOJI_FONTS`, with Apple Color Emoji and Noto Emoji as
fallbacks.

**Single code points only.** A ZWJ sequence such as 👨‍💻 is composed at render time
from several glyphs and has no single outline to take, so it comes back empty — the
generator says so on stderr rather than silently drawing nothing. Use 💻.

The emoji is fitted by its **ink bounding box**, not its advance width, so a
taller-than-wide glyph still lands centred.

## The numbers

| | |
|---|---|
| Page | 445 x 594 pt |
| Side margins | 44 pt, symmetric |
| Title cap top | 54 pt (`margin_top`) |
| Title size | `min(measure / advance(title, 1.0, tracking=0.04), 78)` |
| Title tracking | 0.04 em |
| Baseline | `cap_top + 0.717 * size` — Helvetica's cap height, not the em box |
| Emoji box | 0.70 x page width, centred in the space below the title |
| Gap under the title | 40 pt |
| Tone | black only |

**Margins are 44 pt, not 26.** 26 gives a bigger title (65 pt versus 59 pt, a cap
height of 12.4 px versus 11.2 at thumbnail size) but the pinned toolbar floats over
the left 44 pt of the page and would sit on the "D" whenever the notebook is open.
The thumbnail is unaffected either way, so this trade buys a clean-looking page for
about a pixel of cap height.

**The title size is capped at 78 pt.** Without a cap a short title like "Ops" is set
at 130 pt and reads as shouting rather than as a label.

## Why the title is drawn as shapes, not text

`rm_glyphs.outlines()` renders it in Helvetica-Bold and hands back **filled glyph
outlines**. This looks like the heavier route and is the safer one:

- The template DSL has **no font selection and no bold**, so a `text` item would get
  whatever face the firmware picks — the PDF preview and the installed template
  would not match.
- `fontSize` already cost this skill an afternoon: a non-integer makes the device
  reject the entire file and render the template **blank**, with nothing in the UI to
  say so. A cover has **zero text items**, so it cannot hit that at all. Check with
  `grep '"type": "text"' Cover.template` and expect nothing back.

Counters — the hole in a D — are separate subpaths wound the other way, so the whole
set is filled as **one shape with an even-odd rule**. Filled one at a time they come
out solid.

## Installing it

A cover is a **template**, installed the normal supported way:

```powershell
powershell -File skills/remarkable/scripts/Add-RemarkableCustomTemplate.ps1 `
    -Template '.\Dev leads.template' -Password '<from the device>'
```

Then on the tablet: open the notebook, **page 1**, template picker, pick it. Do not
set it as the notebook default unless you want the artwork behind every page.

The picker gains one entry per covered notebook, so `cover.json` files them under a
`Covers` category. That is the real cost of this approach — see the note at the end.

You cannot get a cover in any other way today. An imported PDF is its own document and
cannot be merged into an existing notebook, so the PDF output here is for previewing
the design, not for shipping it.

## The drawn-icon route, kept but not preferred

`--icons` uses a small hand-drawn library (`rm_icons.py`, `--list-icons`,
`--icon-sheet sheet.pdf`) instead of an emoji. It predates the emoji route. **Use
`--emoji`** — thousands of shapes, no maintenance, drawn by people who can draw.

If you do edit `rm_icons.py`, regenerate the contact sheet and look at it. Four icons
shipped visibly broken in the first draft and the sheet is what caught all four. Two
conventions bite: **angles are counter-clockwise with 0 at 3 o'clock, so 90 is the
top** even though `v` grows downwards; and **`rrect_pts` walks clockwise in four
seven-point corners**, so a speech-bubble tail splices in after index 20 rather than
being appended. For a silhouette of overlapping circles use `lobes()`, which solves
the real intersections — guessed hand-over angles leave a notch or a spike.

## The open design question

A cover is a template, so covering many notebooks means many picker entries. The
alternative is writing the cover into the notebook's own first page as **ink**, which
needs a `.rm` v6 writer (`rmscene` can do it) plus an insert into `cPages.pages` in
`.content` with a fractional index that sorts before the current first page. That is
verified as possible but not built. The `.rmdoc` download is a plain zip of
`.content`, `.metadata` and the page `.rm` files, which is the safest place to do it.
