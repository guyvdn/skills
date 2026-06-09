---
name: reveal-md
description: 'Create, run, and export reveal-md presentations. Use when the user wants to create a new slide deck, serve a presentation locally, or export one to PDF.'
version: 1.0.0
---

# reveal-md Presentations

Create and run Markdown-based slide decks with reveal.js via reveal-md.

## Running a presentation

```powershell
reveal-md.cmd slides.md          # serve on http://localhost:1948
reveal-md.cmd -w slides.md       # serve with live reload
```

## Exporting to PDF

```powershell
reveal-md.cmd slides.md --print slides.pdf
reveal-md.cmd slides.md --print slides.pdf --print-size A4
```

> Use `reveal-md.cmd` (not `reveal-md`) on Windows — the `.cmd` wrapper picks up the correct Node.js path.

## Standard frontmatter template

```yaml
---
title: My Talk
description: run with reveal-md slides.md
theme: dracula
highlightTheme: monokai
revealOptions:
  transition: slide
  controls: true
  progress: true
---
```

## Standard CSS block

Add this after the frontmatter on every new deck:

```html
<style>
  .reveal {
    font-size: 2.2em;
  }

  .reveal blockquote {
    font-size: 0.8em;
    line-height: 1.35;
  }

  .reveal blockquote p {
    margin: 0;
  }
</style>
```

## Slide structure

```markdown
# Title slide

## Subtitle
<!-- .element: class="fragment fade-in-then-semi-out" -->

---

## Next slide

- Bullet one
  <!-- .element: class="fragment fade-in-then-semi-out" -->
- Bullet two
  <!-- .element: class="fragment fade-in-then-semi-out" -->

---

## Slide with quote

> The key insight goes here.
```

### Separators

| Symbol | Meaning |
|--------|---------|
| `---` | Horizontal slide (next) |
| `----` | Vertical slide (nested / down) |

### Fragment effects

The preferred effect is `fade-in-then-semi-out` — each bullet fades in bright and dims when the next appears, keeping the previous items visible but de-emphasised:

```html
- Bullet text
  <!-- .element: class="fragment fade-in-then-semi-out" -->
```

Other useful effects: `fade-in`, `fade-out`, `highlight-red`, `highlight-blue`.

### Speaker notes

```markdown
Visible slide content

Note: This is only visible in speaker view (press S).
```

### Slide backgrounds

```markdown
<!-- .slide: data-background="#1a1a2e" -->
# Slide with custom background
```

### Code with line highlights

````markdown
```js [1|3-5]
const a = 1;
// highlight line 1 first, then lines 3-5
const b = 2;
const c = 3;
const d = 4;
```
````

## Themes

Built-in reveal.js themes: `black`, `white`, `league`, `beige`, `sky`, `night`, `serif`, `simple`, `solarized`, `moon`, `dracula` (preferred).

Built-in highlight themes (monokai preferred for dark decks): `monokai`, `atom-one-dark`, `github`, `zenburn`.

## Gotchas

- On Windows, always use `reveal-md.cmd` — the bare `reveal-md` command fails with a Node path error.
- PDF export uses Puppeteer (headless Chromium). If it fails silently, retry with `--puppeteer-launch-args="--no-sandbox"`.
- Fragment comments must be on the line **immediately** after the element, with no blank line between.
- Vertical separators (`----`) create sub-slides navigated with the down arrow, not the right arrow.
