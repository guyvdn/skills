---
name: interactive-reveal-deck
description: 'Build a presentation as a reveal.js deck with a custom interface and interactive demo panels, instead of static bullet slides. Use when the user wants a slide deck that looks designed rather than templated, asks for a presentation with live/interactive demos, wants a per-part accent colour scheme, a chapter rail, or a jump-to-slide palette, or asks to upgrade an existing reveal-md / mkslides / Markdown deck into a richer reveal.js one. Also use when a deck needs a fake IDE, an animated before/after, a cost or scaling slider, a simulated race, or a protocol/API message exchange walked one frame at a time as a stage demo. Also use when an existing deck built this way needs to be shortened, de-duplicated, made less technical, or turned into a story.'
version: 1.2.0
---

# Interactive reveal.js decks

Builds a deck directly against reveal.js instead of a Markdown wrapper, so it
can carry a designed interface and panels the presenter *drives* on stage.

**Use this when** the deck's value depends on showing a mechanism working — a
generator emitting its output, a fix being applied, one approach beating
another. **Don't use this for** a deck that is genuinely a list of points:
`reveal-md` (see the `reveal-md` skill) is less work and the right answer
there. A widget that only decorates a slide is worse than the bullet it
replaced.

## Before the first slide

Every rework of a real deck built with this skill was about the story, not
the framework: too technical, no thread, the same point on three slides,
pitched at the builders instead of the room. Settle these in the outline,
then read [references/storytelling.md](references/storytelling.md):

- **Who is in the room** and what they cannot do — drop what only the
  presenter or the builders care about.
- **One running thread** (a question, a case) that the parts are chapters
  of, ending each part on its payoff.
- **A slide budget**: about one main-path slide per minute. Count before
  building, not after.
- **Each fact once.** Detail you would only *say* goes in the speaker notes,
  not on a `↓` slide.

## Scaffold

```powershell
powershell -ExecutionPolicy Bypass -File skills/interactive-reveal-deck/scripts/New-RevealDeck.ps1 `
    -Path D:\talks\my-talk\deck -Title "My Talk"
```

Copies `assets/`, installs `reveal.js` + `http-server` locally, writes
`start-deck.ps1` next to the deck. Then edit `index.html` and serve:

```powershell
D:\talks\my-talk\start-deck.ps1        # http://localhost:8081
```

reveal.js is installed **locally, not from a CDN** — conference wifi is not a
dependency you want. Fonts do come from Google Fonts, with real local
fallbacks (Segoe UI, Cascadia Code), so an offline room degrades slightly
instead of breaking.

## What you get

| | |
|---|---|
| Per-part accent | Each part owns a colour. It tints the background glow, headings, rail, buttons, code highlights. Position in the talk becomes legible without reading anything. Set `window.DECK_PARTS` in `index.html`; `id` must match `data-part` on each section. |
| Chapter rail | Left edge, a dot per slide in the current part, click to jump, labels on hover. Built from the parts + slides — nothing to maintain. |
| Command palette | <kbd>/</kbd> or <kbd>Ctrl</kbd>+<kbd>K</kbd>, fuzzy-matches slide titles. **This is the feature that changes how a talk goes** — it answers an out-of-order question without arrowing through 30 slides in front of everyone. |
| Context readout | Top right: part name, plus what this slide affords (`→ runs the panel`, `→ steps through the code`, `↓ more`). The presenter never has to remember which slides are special. |
| Annotation layer | <kbd>D</kbd> draws in the part's accent, <kbd>C</kbd> clears, strokes kept per slide. |
| Code stepping | `data-steps="1-3\|6-9"` turns arrow keys into a walk through highlighted regions of a code block. |
| Keyboard help | <kbd>?</kbd> |

## Slide authoring

Content is plain HTML in `index.html`. Every section gets `data-part` (accent,
rail) and `data-title` (palette, rail). Code goes in
`<script type="text/template">` inside a `figure.code-window`, never in
`<pre><code>`, so it needs no entity escaping. Use the components (`ul.rows`,
`.card`, `blockquote.pull`, `table.matrix`, `.terminal`) rather than bare
HTML — the template has one of each. Details and the language list:
[references/authoring.md](references/authoring.md).

## Widgets

`assets/js/widgets.js` ships the framework and two general-purpose widgets:

- **`pipeline`** — input goes in, generated output comes out line by line.
  Variant buttons change the input and rebuild. The second build is the
  argument: one small change, a different whole output.
- **`calc`** — one slider, several derived numbers. Expressions live in the
  markup (`data-calc="n * 48"`, `data-bar="42 + n"`), evaluated against `n`.

Four more worked patterns — fake IDE with a light-bulb code fix, a token
walking down defence layers, a two-lane race with live counters, and a
protocol exchange walked one message per press — are in
[references/widget-recipes.md](references/widget-recipes.md), with full code.
Their CSS is already in `widgets.css`, so pasting a recipe needs no styling
work.

**The contract, in short:** every widget registers `{ run, reset }`;
<kbd>B</kbd> runs, <kbd>R</kbd> resets, and the presenter remote's *next*
runs the panel before it advances; entering a slide always resets; `run()`
is idempotent; optional `showAll()` is the finished state, used by the PDF
handout and a **Show all** button. Full rules and the registration snippet:
[the widget contract](references/widget-recipes.md#the-widget-contract).

## Verify before presenting

```powershell
powershell -ExecutionPolicy Bypass -File skills/interactive-reveal-deck/scripts/Test-DeckLayout.ps1 `
    -Path D:\talks\my-talk\deck
```

Drives a real browser through every slide with **all fragments shown**, and
reports slides whose content exceeds the 740px frame plus any JS errors.
Content overflow does not error, it just silently runs off the bottom of the
projector — this is the check that catches it. Requires `agent-browser`
(`npm i -g agent-browser`); serves the deck itself and cleans up after.

Fix overflow by trimming the snippet, not by shrinking the frame. `.codelines`
sits at `.37em`; below about `.32em` code stops reading from the back row.

## PDF handout

Serve the deck, then print `http://localhost:8081/index.html?print-pdf` with
headless Chrome (`--print-to-pdf`) — `agent-browser pdf` is US Letter only.
One page per slide (`pdfSeparateFragments: false`). Accents are stamped per
slide, toolbars are hidden, and every widget with a `showAll()` exports
**finished**, so the handout needs no duplicate static slides. A widget
without one exports in its reset state — give it a `showAll()` rather than a
copy slide.

## About to… → read

| About to… | Read |
|---|---|
| Write the outline, cut a long deck, pick examples, put numbers on a widget | [references/storytelling.md](references/storytelling.md) |
| Write slides: code windows, languages, components, stacks | [references/authoring.md](references/authoring.md) |
| Build or adapt a widget | [references/widget-recipes.md](references/widget-recipes.md) |
| Debug fonts, layout, keys, PDF, video embeds, a hung layout check | [references/gotchas.md](references/gotchas.md) |

## Files

| Path | What |
|---|---|
| `assets/index.html` | Slide template — one of every component, two working widgets, the chrome markup, the `Reveal.initialize` call |
| `assets/css/deck.css` | Tokens → theme application layer → components → controls → chrome. Edit the tokens first. |
| `assets/css/widgets.css` | Widget styles, opt-in. Covers all six patterns. |
| `assets/js/code.js` | `DeckCode` — tokenizer, code windows, `data-steps` fragments |
| `assets/js/widgets.js` | `DeckWidgets` — framework + `pipeline` + `calc`, print-mode `showAll` |
| `assets/js/chrome.js` | `DeckChrome` — accents, rail, readout, palette, help, annotation, keys, clicker |
| `scripts/New-RevealDeck.ps1` | Scaffold a new deck |
| `scripts/Test-DeckLayout.ps1` | Overflow + JS-error sweep across every slide |

No build step, and no third-party reveal plugins — only reveal's own `notes`
and `zoom`.
