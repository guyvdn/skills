# Story, audience and length

When a deck built with this skill gets sent back, it is rarely the framework.
The rework is almost always the **story**, **repetition**, or **pitching at
the wrong audience**. Read this before writing the outline, not after the
first review.

## Settle three things before the first slide

Ask, or infer and say so in the outline:

1. **Who is in the room, and what they cannot do.** "Colleagues" is not an
   answer. A talk about a tool is easily pitched at its maintainers (admin
   features, internals, counts of things) when the room is its users.
   Anything only the presenter or the builders care about is out, however
   true.
2. **What they should be able to do or explain afterwards.** One sentence.
   Every main-path slide must move toward it.
3. **The length, as a slide budget.** Minutes → main-path slides, roughly
   **one per minute**, with ↓ slides and speaker notes not counted. Write the
   number in the outline and count before building: cutting a finished deck
   by a third takes several rounds and loses more than planning would have.

## A story, not a topic list

A deck organised like reference documentation — *what it is · why · our
setup · lessons · how to do it yourself · tuning* — reads as too technical
and tells no story. What works instead:

- **One running thread.** A single concrete question or case carries the
  talk: it is why the thing was built, the first thing it did, where it went
  wrong, and what the audience will do with it. Pick the thread before the
  parts; the parts are then chapters of it, not categories.
- **Chronological when the material allows**: the idea → choosing the shape
  → building it → the first days → doing it yourself. A non-specialist can
  follow a sequence of events; they cannot follow a taxonomy.
- **Each part ends with its payoff**, and the next part opens with the
  question that payoff raises.
- **A demo shows the payoff, not the mechanism.** "It processes every event"
  is a mechanism; "by the time anyone looks, the answer is already there" is
  the payoff. End on the frame where a person benefits, and choose the case
  that proves the claim most clearly.
- **A call to action belongs to the pitch it supports**, as its closer, not
  on a slide of its own. Promote only what the organiser wants promoted.

## Plain words on the main path

- **Spell out or replace jargon** the room will not share: a filesystem
  standard becomes *a persistent disk*, *replica* becomes *copy*, an
  abbreviation becomes its full name, a database's internal views become
  *performance stats only, no access to the data*. If you had to look it up,
  or the presenter asks what it means, it is jargon.
- **An analogy introduces a term; it does not replace it.** If the audience
  will meet the real name afterwards, use the real name, with the everyday
  meaning as a tag the first time: *"Skills — its handbook"*. A deck that
  keeps saying "the handbook" leaves them unable to read the docs.
- **An analogy breaks when the story outgrows it.** When adding a part or a
  second case, re-check every metaphor against it.
- **No callbacks that need an earlier slide in memory.** A line that leans
  on a slogan from twenty minutes ago reads as a strange sentence. Say the
  rule again in full, in plain words.
- **Drop what the room already knows** (the office address, the venue of a
  recurring event) and **what does not apply to them** (a component they
  will never run, config keys, a bug that only the builders hit).

## Say each thing once

Repetition is the most common cut. Before calling a deck done, look for
these:

| Pattern | Fix |
|---|---|
| A comparison table that restates the slide above it | Keep one; the table only if it adds a row the prose doesn't |
| An overview slide ("the six steps") followed by one slide per step | Drop the overview; put the step number in each heading |
| A later part that repeats an earlier one ("then the same steps, but here") | Refer back in one line; show only what differs |
| A config slide whose gotchas are also on a traps slide | One home per fact |
| Two slides telling one beat (the symptom, then its cause) | Merge into one slide with the cause as the second half |
| A demo, then a static slide carrying the same point | Delete the static slide and give the widget a `showAll()`, which is both the handout and the stage fallback |
| The same claim in heading, body and pull quote | Heading states it, body proves it, no quote |
| A `↓` slide for every main slide | Default to speaker notes; keep a `↓` slide only for something you would actually show when asked (an architecture diagram, the real config) |

Vertical stacks are for detail you will **show** if asked. Detail you would
only **say** belongs in the speaker notes of the slide above. Moving most
"under the hood" slides into notes usually loses nothing.

## Examples the presenter can tell

An example on a slide is something the presenter has to narrate in two
sentences. If they can't, the card is unclear, however accurate it is.

- **Card title = what the people involved saw** ("Alert: the mail service
  fails"). **Card text = what happened**, in plain words. **Speaker notes =
  a two- or three-sentence script** per card, in card order.
- **Prefer the example that shows something nothing else could** (a problem
  no existing check would have caught) over the one that is merely real.
  Vague examples get sent back.
- **Real data, sourced.** Say in the notes where each example came from, and
  keep the honest caveat where there is one (the system once got it wrong).

## Be honest about simulated numbers

A widget showing "1,840 ms" and "12,000 allocations" reads as a benchmark.
If it is a model, **say so in the speaker notes and say so on stage before
someone asks.** The shape being real is a fine claim; the digits being
measured is not, unless they are. This is the one way these panels can cost
you credibility instead of earning it.

## The author's content is the author's

When a technical problem touches content — a video that will not embed, an
example that does not fit — fix the technical problem or ask. Do not swap in
a different video or example to make the symptom go away. Same for cutting
a part the author asked for: propose it, don't do it.

## Review pass before handing it over

Have a fresh subagent read the whole deck against its sources. It finds
overclaims and unsourced numbers the author has already read past. Give it
this list:

- every claim checked against the repo, logs or records it came from;
  overclaims ("handles every case", "access to everything") toned to what is
  true;
- the slide count against the budget;
- repetition, using the table above;
- jargon on the main path;
- anything identifying a customer or person that must not be named;
- headings and quotes that only make sense with an earlier slide in memory.
