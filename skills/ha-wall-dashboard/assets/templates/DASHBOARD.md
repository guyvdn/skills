# {{NAME}} — dashboard notes

Started {{DATE}}. This file is the dashboard's memory: what was chosen, why,
and what turned out to be surprising. Keep it current; the next session (human
or agent) starts here.

## Setup progress

The user's decisions in the setup wizard. Tick each one only once the user has
answered (or explicitly left it to the agent; say so). The final config isn't
written while any box is open.

- [ ] Display measured (size, touch or view-only, viewing distance → scale)
- [ ] Theme chosen (on the tablet, via themes.html)
- [ ] Language / locale
- [ ] Panels
- [ ] Entities, names and icons
- [ ] Layout

## Setup

| | |
|---|---|
| Home Assistant URL | |
| HA install type | (HA OS / Container / Supervised / Core) |
| How files reach HA | (Samba add-on / Studio Code Server / SSH / other) |
| Deploy target | (`dashboard.project.json` → deployTo) |
| Dashboard URL | `<ha>/local/{{NAME}}/index.html` |
| HA user for the tablet | |

## Display

| | |
|---|---|
| Device | |
| Browser / kiosk app | |
| Measured viewport | (from measure.html — not the spec sheet) |
| Orientation | |
| Touch | (yes / view-only) |
| Notes | (colours that render badly, glare, viewing distance) |

## Look

- Theme:
- Overrides / scale:
- Language / locale:

## Panels and entities

One line per panel: what it shows, which entities, and why those.

## Quirks and gotchas found

Dated entries. Integration behaviour, renamed entities, values that lie.

## Decisions

Things deliberately done (or not done), with the reason, so nobody re-litigates them.
