---
name: ha-wall-dashboard
description: 'Build and maintain a Home Assistant wall-tablet dashboard: a standalone, themeable vanilla-JS web app served from HA''s own www folder, live over the WebSocket API. Use when someone wants a wall/kiosk/tablet dashboard for Home Assistant, asks to set one up from scratch (a guided wizard discovers their entities, picks panels, theme and layout), or wants to change an existing one — add or move a panel, swap an entity, change the theme, fix a panel showing dashes or stale values, deploy, set up the tablet (Fully Kiosk), or upgrade to a newer starter. Not for Lovelace YAML dashboards.'
version: 1.0.0
compatibility: 'Home Assistant 2024.3+ (any install type) with write access to its config/www folder. Node 22+ on the machine running the scripts. Any modern tablet browser; Android + Fully Kiosk Browser recommended.'
---

# Home Assistant wall dashboard

A dashboard for a tablet on the wall: big type, glanceable, touch-first, always
on. It is **not** a Lovelace dashboard. It is a small static web app (no build
step, no framework) in HA's `config/www/<name>/`, served by HA itself at
`/local/<name>/index.html`. It talks to HA over the same WebSocket API that HA's
own frontend uses.

The design came out of a dashboard that has run daily on a real wall for months.
Every gotcha in [references/gotchas.md](references/gotchas.md) was learned the hard way. **Do not
"simplify" away anything that file explains.**

## How it is put together

```
<project>/
  dashboard.project.json   name, HA url, deploy target
  DASHBOARD.md             THIS home's notes: hardware, choices, quirks — read it first
  CLAUDE.md                points future sessions at this skill
  www/                     the web app, deployed as-is to config/www/<name>/
    dashboard.config.js    everything home-specific: theme, layout, panels, entities
    config.local.js        the HA token (gitignored, but served — see deploy.md)
    index.html  core/  panels/  style.css  fonts/
    themes.html            every theme on fake data — open it ON the tablet
    measure.html           reports the real viewport size of the tablet
    tests/                 node --test, not deployed
```

Home-specific = `dashboard.config.js`. Prefer config changes to code changes;
a new kind of panel is the main reason to write code.

## Scripts (Node 22+, run from anywhere)

`<skill>` below is this skill's directory.

| Script | What it does | Writes |
|---|---|---|
| `node <skill>/scripts/scaffold.mjs --to <dir> --name wall` | New project from the starter | the project dir |
| `node <skill>/scripts/scaffold.mjs --to <dir> --upgrade` | Pull in a newer starter; keeps locally edited files | `www/` |
| `node <skill>/scripts/discover.mjs --project <dir>` | Inventory HA, group entities per panel type | `inventory.json` |
| `node <skill>/scripts/check-config.mjs --project <dir>` | Every entity exists, every type/icon is known | nothing |
| `node <skill>/scripts/deploy.mjs --project <dir>` | Copy `www/` to HA and cache-bust it | HA `config/www/<name>/` |

The token comes from `$HA_TOKEN` or the project's `www/config.local.js`, never
from a command-line flag (shell history). All scripts except `deploy` and
`scaffold` are read-only against HA, and **nothing in this skill ever changes HA
configuration** — it only reads states and calls services when the user taps.

## Load what the task needs

| Task | Read |
|---|---|
| **New dashboard, start to finish** | [references/wizard.md](references/wizard.md) — drives everything else |
| Making sense of `inventory.json`, picking entities | [references/discovery.md](references/discovery.md) |
| Panel types, every config option, layout sizing | [references/panels.md](references/panels.md) |
| Choosing or making a theme, colour rules | [references/themes.md](references/themes.md) |
| Getting files onto HA, token, tablet user, caching | [references/deploy.md](references/deploy.md) |
| The tablet: kiosk browser, screen, touch | [references/kiosk.md](references/kiosk.md) |
| Changing a running dashboard, new panel types, upgrades, troubleshooting | [references/maintain.md](references/maintain.md) |
| Before any non-trivial code change | [references/gotchas.md](references/gotchas.md) |

## Rules that hold in every task

- **Read `DASHBOARD.md` first** in an existing project, and **update it** whenever
  something non-obvious is learned or decided. It is the dashboard's memory.
- **Same origin, always.** The app must be opened from HA's own host and port, and
  derives the API URL from `location`. Never hardcode an IP or hostname in the app.
- **Run `check-config.mjs` and `node --test www/tests/*.test.mjs` before every
  deploy.** The glob matters; a bare `tests/` directory argument misbehaves on some Node + shell combinations.
- **Verify on the tablet, not on a monitor.** Colours, sizes and touch all differ.
  A screenshot from a desktop browser is not verification of a visual change.
- **Confirm before deploying** to the user's HA the first time in a session, and
  before anything that writes outside `config/www/<name>/` (the deploy script refuses that anyway).
- The token in `config.local.js` is readable by anyone on the LAN who knows the URL.
  Say so once during setup; recommend a dedicated HA user for the tablet.
