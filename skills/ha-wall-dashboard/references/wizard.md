# Setup wizard

A guided first build, in seven steps. Each step ends with something concrete
(a file, a number, a decision recorded in `DASHBOARD.md`), so the wizard can
stop and resume across sessions: the next session reads `DASHBOARD.md` and
picks up at the first step whose result is missing.

## The user's decisions

These are the user's to make, **every one explicitly asked**. The starter ships
defaults for all of them (theme `tron`, scale `1`, the example panels) so that it
runs, and a default that is never asked about quietly becomes the user's
dashboard. That's how a test run ended up on `tron` without the user ever
seeing the theme choice.

| Decision | Asked in step |
|---|---|
| Display size, touch or view-only, viewing distance (→ `scale`) | 2 |
| **Theme** (and day/night switching, accent override) | 2 |
| Language / locale | 2 |
| Panels | 4 |
| Entities, names and icons per panel | 5 |
| Layout | 6 |

Track them in `DASHBOARD.md` → Setup progress, ticking each one when the user
has answered. **Step 7 doesn't start while any box is unticked.** If the user
says "you choose", that counts as an answer: record "user left it to me" and
what you picked.

**Tone:** the user knows their house; you know the dashboard. Propose, don't
interrogate. Each step: show what you found, make a recommendation, ask only
what cannot be inferred. For real choices use the agent's structured question
tool if it has one (in Claude Code: `AskUserQuestion`, max 4 options per question,
4 questions per call), otherwise a short numbered list. Put the recommended
option first either way. Long
lists, like 19 lights, go in a table in chat with a proposed selection the
user edits in one reply, not 5 rounds of 4 checkboxes.

## 1. Prerequisites

Establish, and write into `DASHBOARD.md` → Setup:

1. **HA URL** as the tablet will use it (`http://homeassistant.local:8123`, an IP,
   or an https name). If HA is behind https, the dashboard must be opened over https too.
2. **How files reach `config/www`.** Ask what they already use; see
   [deploy.md](deploy.md) for the options per install type. You need a path that
   this machine can write to. **On Windows, write share paths with forward
   slashes** (`//homeassistant.local/config/www/wall`): Windows accepts them, while a
   `\\host\share` path loses backslashes on its way through shells and JSON. On
   macOS and Linux the target is wherever the share is mounted
   (`/Volumes/config/www/wall`, `/mnt/ha/www/wall`). There, `//host/...` is not a share.
   **List what is already in `www`.** An existing dashboard or other app there
   must not be overwritten, so pick a `<name>` that's not taken, and record
   "never deploy into `www/<other>`" in `DASHBOARD.md` → Decisions.
   The `www` folder may not exist yet. That's normal, and the deploy creates it. An HA restart
   is needed once after `www` is first created, before `/local/` serves anything.
3. **Node 22+** (`node --version`). The scripts need its built-in WebSocket.
4. **Two tokens, two places.** This is the one security rule of the wizard:
   - **Discovery** reads HA's registries, which needs an **admin** token: the user's
     own. It goes only into the `HA_TOKEN` environment variable, for the commands
     that need it, and **never into a file**.
   - **The tablet** gets a token from a dedicated **non-admin** HA user (see
     [deploy.md](deploy.md) → "The tablet's HA user"). That one goes in
     `www/config.local.js`, which HA serves **without any login** to anyone who can
     reach `/local/`, including the internet if HA is exposed via Nabu Casa or a proxy.

   `deploy.mjs` checks this: it refuses to deploy a `config.local.js` holding an
   admin token unless `--allow-admin` is given. Only suggest `--allow-admin` if the
   user explicitly accepts the risk for a short test on a LAN-only HA.

Then scaffold:

```
node <skill>/scripts/scaffold.mjs --to <project dir> --name <name> --ha-url <url> --deploy-to <path>
```

`<name>` becomes the URL (`/local/<name>/`). Short, lowercase: `wall`, `hallway`.
If HA is reachable from the internet, suggest a less guessable name: it's the
only thing between a stranger and the tablet token.

**Never ask for a token in the chat.** The user pastes the tablet token into
`www/config.local.js` themselves, or copies it to the clipboard and you move it
from there without displaying it. Check it looks like a token (three base64url
parts separated by dots):

```powershell
# Windows (PowerShell)
$t = (Get-Clipboard -Raw).Trim()
if ($t -notmatch '^[\w-]+\.[\w-]+\.[\w-]+$') { 'Clipboard does not hold a token'; exit 1 }
Set-Content -Encoding utf8 www\config.local.js "export const HA_TOKEN = '$t';"
```

```bash
# macOS: pbpaste · Linux: wl-paste (Wayland) or xclip -selection clipboard -o (X11)
t=$(pbpaste | tr -d '[:space:]')
[[ $t =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || { echo 'Clipboard does not hold a token'; exit 1; }
printf "export const HA_TOKEN = '%s';\n" "$t" > www/config.local.js
```

The admin token for discovery travels the same way, but into the environment
of the one command that needs it, never into a file or the command line itself:

```powershell
$env:HA_TOKEN = (Get-Clipboard -Raw).Trim(); node <skill>/scripts/discover.mjs --project .; Remove-Item Env:HA_TOKEN
```
```bash
HA_TOKEN=$(pbpaste | tr -d '[:space:]') node <skill>/scripts/discover.mjs --project .
```

`discover.mjs` prints which user the token belongs to, and whether it's an admin.
That's the check that the token works, without ever showing it.
Suggest `git init` in the project.

## 2. At the tablet: measure, and pick the look

One trip to the tablet covers both. The theme preview runs on fake data, so it
doesn't need the entities yet, and choosing the look early makes the rest of the
wizard feel like *their* dashboard. Deploy once (the example config is fine),
then send the user to the tablet with **both** pages in one message:

1. **`<ha>/local/<name>/measure.html`**, in the browser it will really run in,
   with fullscreen on. Ask for the big number (CSS pixels, e.g. `1280 × 800`), and
   whether the cyan frame touches all four edges. If it doesn't, a system bar overlaps
   the page: fix the browser's fullscreen settings first ([kiosk.md](kiosk.md)).
   Also ask for the **time zone** line. If it differs from HA's (`ha.timeZone` in
   the inventory), the tablet's clock setting needs fixing ([kiosk.md](kiosk.md) → Time zone).
2. **`<ha>/local/<name>/themes.html`**: tap the buttons bottom-right to go through
   the themes. The tiles can be tapped too, to see what "on" looks like.

Then ask, in one go (one question-tool call, or one numbered list):

- **Theme.** Recommended first, based on the room if you know it (dark room or night
  viewing: `tron` or `nord`; bright room: `daylight`):

  | Theme | Feel |
  |---|---|
  | `tron` | dark navy glass, cyan neon glow. The original. |
  | `synthwave` | violet, hot pink neon, retro-mono type |
  | `nord` | calm, flat, frosty blue-grey; no glow |
  | `amber` | retro CRT terminal, amber on black, scanlines |
  | `daylight` | light, white cards; for bright rooms |

  With four options per question, offer the three likeliest plus `daylight`, and
  say that the fifth is available via "Other". Mention **follow the sun**
  (`theme: { day: 'daylight', night: '<dark theme>' }`, switching with `sun.sun`) and
  that a different accent colour is an override, not a new theme ([themes.md](themes.md)).
- **Touch or view-only?** View-only drops toggles and climate controls.
- **Viewing distance?** Across a room means `scale: 1.2`–`1.4`; next to a door at arm's length, `1`.
  `themes.html?scale=1.2` previews a size.
- **Language.** Propose the one from HA's settings (the inventory has it, or ask).

Record the answers in `DASHBOARD.md` → Display and Look, **and set `theme`,
`scale` and `locale` in `dashboard.config.js` now and redeploy**, so the wall
already shows their choice while the rest is being built. If the user can't get to
the tablet right now, the questions still get asked, from a desktop browser, with
a note to check on the tablet later.

## 3. Discover

```
node <skill>/scripts/discover.mjs --project <project dir>
```

Read the printed summary and `inventory.json` → `candidates`. Use
[discovery.md](discovery.md) to clean it up: duplicates, the car showing up as
"doors", entities that are technically lights but really plugs, and so on. Show the user a
**short** picture of their house: areas, and per group how many usable
entities, with 2–3 examples each. Don't dump the inventory.

## 4. Choose panels

Recommend a set from what exists. A good default for a family wall:
clock, weather, calendar, lights, climate (if any), energy (if a meter exists),
plus one "attention" panel (doors/windows, or who is home).

Ask as a multi-select (with `AskUserQuestion`: two questions of up to 4 options
each), *only offering panels whose candidates exist*. The panel catalogue is in
[panels.md](panels.md). Mention the "glance test": everything on the wall should
be readable from across the room in two seconds. A dozen panels fails it.
**6–9 panels is the sweet spot on a 10" tablet.**

## 5. Choose entities per panel

For each chosen panel, propose a selection from the candidates in a table:
entity, proposed tile name, proposed icon, area, and current state (so the user
recognises it). Rules of thumb:

- **Names short, in the user's language.** Long names shrink to fit (down to 65 %
  of normal size, then an ellipsis), so "Woonkamer" is fine. "Living room ceiling
  lights" is not. Never translate room names just to make them fit.
- **3–6 toggles** per panel; more than 9 tiles won't be tappable.
- Lights: prefer the **room group or area light** over individual bulbs.
- Energy: a lifetime counter (`total_increasing`) with `today: true` (the default
  for `energy`) shows today's use; a power sensor (W) needs `today: false`.
- Calendar: `upcoming30d` in the inventory says how many events each calendar
  has in the next 30 days. **Don't propose a calendar with 0** without saying so;
  an empty agenda reads as broken. Ask for a colour per calendar that stands out
  from the theme's accent (see [themes.md](themes.md)). Holiday or school calendars
  often contain week-long blocks; set `skipMultiDay: true` for those.
- Appliances and other enum sensors (`run`/`stop`/`finished`): a `status` item
  with `activeStates` picked from the entity's `options` in the inventory. The
  same entity can appear twice with different `activeStates`, for example
  "running" and "done, empty it".

Record the final picks, and *why* where it isn't obvious, in `DASHBOARD.md`.

## 6. Layout

Propose the columns as an ASCII sketch, sized for the measured viewport:

```
┌──────────┬─────────────┬──────────┐
│ weather  │   clock     │ lights   │
├──────────┤─────────────┤──────────┤
│ climate  │  calendar   │ energy   │
│          │   (×2)      ├──────────┤
│          │             │ doors    │
└──────────┴─────────────┴──────────┘
```

Rules from [panels.md](panels.md) → Layout: 3 columns for landscape 16:10, 2 for
4:3 or portrait; the calendar wants height; tile panels want width ÷ items ≥ ~120 CSS px.
Confirm with the user. Ask once; adjust after they see it on the wall.

## 7. Generate, check, deploy, hand over

Check `DASHBOARD.md` → Setup progress first. An unticked decision goes back to
the user now, not after the deploy.

1. Write `www/dashboard.config.js` from the decisions: theme, scale and locale as
   chosen in step 2, then the columns. Comment anything non-obvious inline.
2. `node <skill>/scripts/check-config.mjs --project <dir>`. Fix every FAIL.
3. `node --test www/tests/*.test.mjs` (from the project dir).
4. Deploy (confirm first): `node <skill>/scripts/deploy.mjs --project <dir>`.
5. The user opens `<ha>/local/<name>/index.html` on the tablet. Walk through
   [kiosk.md](kiosk.md) for the kiosk app if they haven't set it up.
   For your own sanity check in a desktop browser (Playwright at the measured
   size): save screenshots inside the project (`.playwright-mcp/`, gitignored).
   The browser tool usually can't write outside the working directory.
6. Ask what looks wrong **on the tablet**. Iterate on scale, sizes and names. Expect
   2–3 rounds; that's normal.
7. Finish `DASHBOARD.md`. Every section should be filled or explicitly "n/a".
   Commit if it's a git repo **and the user asks for it**.
8. Hand over with a short "how to change it later": the theme, scale, a panel or
   a name are all one line in `dashboard.config.js`, and the user can simply ask for it.
   `themes.html` stays deployed for when they want to look again.

## Resuming

If `DASHBOARD.md` exists, read it, say which steps are done and which is next,
and continue from there. Re-run discovery only if it's older than the user's last
HA change, or if `check-config` reports missing entities.
