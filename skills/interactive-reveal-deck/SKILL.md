---
name: interactive-reveal-deck
description: 'Build a presentation as a reveal.js deck with a custom interface and interactive demo panels, instead of static bullet slides. Use when the user wants a slide deck that looks designed rather than templated, asks for a presentation with live/interactive demos, wants a per-part accent colour scheme, a chapter rail, or a jump-to-slide palette, or asks to upgrade an existing reveal-md / mkslides / Markdown deck into a richer reveal.js one. Also use when a deck needs a fake IDE, an animated before/after, a cost or scaling slider, a simulated race, or a protocol/API message exchange walked one frame at a time as a stage demo.'
version: 1.1.0
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
| Context readout | Top right: part name, plus what this slide affords (`B run · R reset`, `→ steps through the code`, `↓ more`). The presenter never has to remember which slides are special. |
| Annotation layer | <kbd>D</kbd> draws in the part's accent, <kbd>C</kbd> clears, strokes kept per slide. |
| Code stepping | `data-steps="1-3\|6-9"` turns arrow keys into a walk through highlighted regions of a code block. |
| Keyboard help | <kbd>?</kbd> |

## Slide authoring

Content is plain HTML in `index.html`. Three conventions:

**1. Every section needs `data-part` and should have `data-title`.**
`data-part` drives the accent and the rail; `data-title` is what the palette
and rail show (falls back to the slide's `h1`/`h2`).

**2. Code goes in `<script type="text/template">`, never in `<pre><code>`.**

```html
<figure class="code-window" data-code data-lang="csharp"
        data-file="TypoAnalyzer.cs" data-tag="APP1001" data-steps="1-2|6-11">
  <script type="text/template">
public override ImmutableArray<string> FixableDiagnosticIds => ["APP1001"];
  </script>
</figure>
```

Script raw text is not parsed as markup, so generics, JSX and HTML snippets
need **no entity escaping** and stay copy-pasteable straight out of the real
source file. `data-lang` is `csharp`, `json` (comments allowed — real config
files are JSONC), `js` / `ts`, `markdown` or `text`. Add more by registering a
function of `(src) -> highlighted HTML` in `LANGS` in `js/code.js`.

**3. Use the components, not bare HTML.** `ul.rows` (not a bare `ul`),
`.card` / `.card.good` / `.card.bad`, `blockquote.pull` (`.pull.hero` for the
big one), `table.matrix` with `td.win` / `td.lose`, `.terminal`,
`section.part-divider`, `section.title-slide`. The template has one of each.

Put optional depth in a **vertical stack** — a `<section>` wrapping sibling
sections. The context readout says `↓ more` automatically, so detail you'll
only show if asked stays out of the linear path but stays reachable.

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

### The widget contract

Every widget registers `{ run, reset }` for its slide.

- **<kbd>B</kbd> runs, <kbd>R</kbd> resets.** Non-negotiable: a panel you can
  only drive with a mouse is a panel you fumble on stage.
- **Entering a slide always calls `reset()`.** A second pass through the deck
  must behave like the first. Never rely on state surviving navigation.
- **`run()` must be idempotent.** Guard animations with a `busy` flag or a
  clicker double-tap desyncs the panel.
- Register your own in a separate file loaded *before* `chrome.js`:

```js
DeckWidgets.register('myThing', function (el) {
  const section = el.closest('section');
  function run()   { /* ... */ }
  function reset() { /* ... */ }
  reset();
  DeckWidgets.own(section, { run, reset });
});
```

### Be honest about simulated numbers

A widget showing "1,840 ms" and "12,000 allocations" reads as a benchmark.
If it is a model, **say so in the speaker notes and say so on stage before
someone asks.** The shape being real is a fine claim; the digits being
measured is not, unless they are. This is the one way these panels can cost
you credibility instead of earning it.

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

`http://localhost:8081/index.html?print-pdf` then print to PDF. One page per
slide (`pdfSeparateFragments: false`). Widgets export in their **reset**
state, so give every widget a nearby static slide carrying the same point —
that slide is also the fallback when a live demo misbehaves.

## Gotchas

These are the ones that cost real time.

**reveal.css contains almost no typography.** A *theme* file is what binds the
`--r-*` variables to selectors. Write your own theme that only *defines* the
variables and every `font-family` resolves to Times New Roman, silently — the
custom properties inspect as correct, which sends you looking in the wrong
place. `deck.css` has a **theme application layer** section for exactly this.
Do not delete it, and if you start a theme from scratch, port it.

**`<span>` with a `height` collapses.** Progress bars and meters written as
`<span class="track"><span class="fill">` render as a 1px line until both get
`display: block`. The bar looks *absent*, not broken, so it reads as a data
bug rather than a CSS one.

**Absolutely positioned children need an explicit `left`.** Without one they
sit at their static position — which, inside a container with `padding-left`,
is *after* the padding, on top of the content you were avoiding.

**`margin: 0.07`, not the default.** The chapter rail lives outside the slide,
in the letterbox. At the default margin there is no letterbox at 16:9 and the
rail sits on the leftmost content.

**Reveal's own keys must be released before you bind them.**
`keyboard: { 66: null, 67: null, 68: null, 82: null, 191: null }` frees
<kbd>B</kbd> <kbd>C</kbd> <kbd>D</kbd> <kbd>R</kbd> <kbd>/</kbd>. Reveal binds
<kbd>B</kbd> to pause — a black screen mid-demo, which is a confusing failure
to debug live.

**`?print-pdf` runs on screen, not in print media.** Custom chrome needs
hiding under `html.print-pdf` as well as `@media print`, or the rail and the
context pill land in the handout.

**Tokenize the whole block, then split lines.** A block comment is one token
spanning newlines; splitting first breaks it, splitting after needs the
span-rebalancing that `splitTokenizedLines()` does.

**Backward navigation shows all fragments.** Reveal does this by design. When
testing a fragment sequence, arrive at the slide going forwards, or you will
think your fragments are broken.

**The scripts here must keep their UTF-8 BOM.** Windows PowerShell 5.1 reads a
BOM-less file as Windows-1252, so an em dash becomes three characters — the
last of which is a curly quote that PowerShell accepts as a *string delimiter*.
The file then fails to parse tens of lines later, pointing at innocent code.
`pwsh` 7 assumes UTF-8 and shows none of this, so `[Parser]::ParseFile` under
7 is not a check that 5.1 will load it.

## Files

| Path | What |
|---|---|
| `assets/index.html` | Slide template — one of every component, two working widgets, the chrome markup, the `Reveal.initialize` call |
| `assets/css/deck.css` | Tokens → theme application layer → components → controls → chrome. Edit the tokens first. |
| `assets/css/widgets.css` | Widget styles, opt-in. Covers all six patterns. |
| `assets/js/code.js` | `DeckCode` — tokenizer, code windows, `data-steps` fragments |
| `assets/js/widgets.js` | `DeckWidgets` — framework + `pipeline` + `calc` |
| `assets/js/chrome.js` | `DeckChrome` — accents, rail, readout, palette, help, annotation, keys |
| `references/widget-recipes.md` | Four more widget patterns, with full code |
| `scripts/New-RevealDeck.ps1` | Scaffold a new deck |
| `scripts/Test-DeckLayout.ps1` | Overflow + JS-error sweep across every slide |

No build step, and no third-party reveal plugins — only reveal's own `notes`
and `zoom`.
