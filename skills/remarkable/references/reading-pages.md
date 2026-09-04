# Reading the pages

You are the OCR engine. These rules exist because the failure mode of handwriting
transcription is not "it gave up" — it is **a fluent, confident, wrong reading that the
user cannot detect**, because it is their own note and they trust it was copied.

## The honesty rules

1. **Never fill a gap with a plausible word.** If you cannot read it, write
   `[illegible]`. If you can nearly read it, write your reading with a question mark:
   `Kafka[?]`. If two readings are both plausible and they mean different things,
   give both: `[retry | rétry?]`.
2. **Never smooth out nonsense.** If the note genuinely says something odd, transcribe
   the odd thing. Notes are not prose and are allowed to be fragmentary.
3. **Do not invent structure.** If the page is a loose cloud of phrases, the transcript
   is a loose list of phrases — not a tidy hierarchy you inferred.
4. **Collect every `[illegible]` into the summary** with its page number. That list is
   the user's instruction for which pages to go and look at themselves. A summary that
   silently drops the unreadable bits is the worst possible output.

## Reading order and batching

Read pages in order, 5–10 at a time. Two reasons:

- **Handwriting is learned.** Accuracy on page 20 is much higher after 19 pages of the
  same hand. A word that is a coin-flip in isolation is obvious in context.
- **Vocabulary repeats.** A scrawled project name on page 9 is usually printed
  legibly the first time it appears. Go back and fix earlier `[illegible]`s once a term
  becomes clear, and say in the transcript that you did.

Do not read pages out of order to "get to the interesting one" — you lose both effects.

## What to transcribe versus describe

| On the page | In the transcript |
|---|---|
| Words, lists, headings | Transcribe verbatim |
| A box, arrow, or flow between ideas | Describe: `[box: "auth svc"] --> [box: "token cache"]` |
| A sketch, wireframe, chart | One-line description of what it shows, plus any labels transcribed |
| A table | Reproduce as a Markdown table |
| Struck-through text | Keep it, marked: `~~use Redis~~` — a crossing-out is a decision |
| A star, circle, exclamation mark | Keep the emphasis: `**(starred)**` |
| Checkboxes | `- [ ]` / `- [x]` as drawn |
| Page-corner dates, page numbers | Keep them; they anchor everything else |

Diagrams are where the value is highest and transcription is worst. Describe the
*relationship* the drawing encodes, not the strokes: "three services in a row, arrows
left to right, a dashed line back from the third to the first labelled 'retry'".

## Layout on the page

reMarkable pages are often two-dimensional — a margin column, a box in the corner,
arrows crossing the page. Read the main flow first, then note the rest explicitly:

```markdown
## Page 7

Main column:
- ...

Left margin: "ask [name?] about licensing"
Bottom-right box: [diagram: ...]
```

Do not silently interleave a margin note into the main flow. Where a note sits is
information — margin notes are usually later additions or asides.

## Language

Keep the transcript in the language written. Mixed-language notes (a Dutch sentence
with English technical terms) stay mixed — that is how the user thinks and normalising
it loses meaning. Write the *summary* in whatever language the user asked in, and say
so if it differs from the notes.

## Pages with a text layer

If `manifest.json` says `has_text_layer: true`, the `text` field is real extracted
text. Use it verbatim; do not re-read it from the image and do not "correct" it. Look
at the image only for handwritten ink on top — that ink is the whole point of an
annotated PDF, and it is invisible in the text layer.

## When a page is unreadable

Do not push the DPI up and retry silently — say so. Re-render just those pages:

```bash
python skills/remarkable/scripts/pdf_to_pages.py source.pdf --out pages-hi --pages 9,14-16 --dpi 250
```

If it is still unreadable at 250 DPI it is unreadable, full stop. Record it as
`[illegible]` and move on. Two escalations is the limit — beyond that you are
guessing with extra steps.

## Summarising

The summary is not a shorter transcript. Handwritten notebooks have a specific shape,
and the useful output follows it:

- **Threads, not pages.** Notebooks return to the same 3–6 topics across scattered
  dates. Group by thread and cite the pages, rather than walking the notebook front to
  back.
- **Unanswered questions are the highest-value output.** Anything the user wrote with a
  question mark and never resolved later in the notebook. These are what a person
  cannot find by flipping pages, and they are exactly what got forgotten.
- **Decisions need their page.** "Settled on X (p.14)" is actionable; "settled on X"
  is trivia.
- **Actions verbatim.** Do not rewrite a TODO into your own words — the user's phrasing
  is the memory hook. Mark it done if it is ticked or struck through.
- **Resist inventing significance.** A shopping list in the middle of architecture
  notes is a shopping list. Say so, or leave it out; do not theorise about it.
