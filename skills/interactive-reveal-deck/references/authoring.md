# Slide authoring

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
files are JSONC), `js` / `ts`, `yaml`, `markdown` or `text`. Add more by registering a
function of `(src) -> highlighted HTML` in `LANGS` in `js/code.js`.

**3. Use the components, not bare HTML.** `ul.rows` (not a bare `ul`),
`.card` / `.card.good` / `.card.bad`, `blockquote.pull` (`.pull.hero` for the
big one), `table.matrix` with `td.win` / `td.lose`, `.terminal`,
`section.part-divider`, `section.title-slide`. The template has one of each.

Put optional depth in a **vertical stack** — a `<section>` wrapping sibling
sections. The context readout says `↓ more` automatically, so detail you'll
only show if asked stays out of the linear path but stays reachable. Detail
you would only *say* belongs in the speaker notes instead — see
[storytelling.md](storytelling.md#say-each-thing-once).
