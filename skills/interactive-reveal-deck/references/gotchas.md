# Gotchas

Read the one that matches before debugging: each of these cost real time.

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

The same goes for the **files the scripts read**: `Get-Content` in 5.1
decodes the BOM-less `index.html` template as Windows-1252 too, so the
scaffold wrote mojibake and missed its title marker. Read and write them with
`[IO.File]::ReadAllText` / `WriteAllText` and an explicit `UTF8Encoding`, and
test a script change under `powershell`, not `pwsh`.

**Don't pipe `Test-DeckLayout.ps1` from an agent's shell tool.** With
`| Select -Last 40` the agent-browser daemon outlives the script and keeps the
pipe open, so the tool call hangs long after the result is in, and because
`Select -Last` buffers, it looks stuck at "Walking every slide". Use
`Start-Process ... -RedirectStandardOutput <file>`, wait on the process, then
read the file.

**C# keywords newer than the tokenizer render as plain identifiers.** `union`,
`closed`, `extension` and `field` were added for C# 14/15. When a new language
version adds contextual keywords, add them to `CS_KEYWORDS` in `js/code.js`.

**Entities in a `<script type="text/template">` are not decoded.** The same
raw-text rule that spares you escaping generics means `Q&amp;A` in a template
is typed out on stage as `&amp;`. Write the bare `&` there. In normal
slide HTML, `&amp;` is still right.

**`agent-browser pdf` only produces US Letter.** A 16:9 deck lands
letterboxed. Print with headless Chrome instead, which honours the deck's CSS
page size:
`chrome --headless --print-to-pdf=deck.pdf "http://localhost:8081/index.html?print-pdf"`.

**reveal caps embedded media at 95%.** Its default `max-width` / `max-height`
on `iframe` and `video` leaves a black band on the right and bottom of a
video frame. Override with `max-width: none; max-height: none` on the frame's
iframe.

**A YouTube embed can fail in one browser profile and play in another.**
"Video unavailable" in the presenter's signed-in Chrome while a clean profile
plays it is a profile or account restriction, not the deck. Test the
embedded videos in the browser you will present from, and do not swap the
author's video to make the symptom go away.
