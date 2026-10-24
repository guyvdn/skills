# Panels and layout

Everything here is set in `www/dashboard.config.js`. Every panel accepts:

| Key | Meaning |
|---|---|
| `type` | one of the types below (required) |
| `size` | relative share of its column's height (default 1) |
| `title` | optional small heading above the panel |

Entity ids are checked by `check-config.mjs`. Icon names are
[Material Design Icons](https://pictogrammers.com/library/mdi/) names without
the `mdi:` prefix, limited to those in `www/core/icons.js`. `check-config` flags
unknown ones. To add one, copy the SVG path from pictogrammers into `ICONS`.

## The catalogue

### `clock`
Big time and the date, in the configured locale and in **Home Assistant's time
zone** (or the top-level `timeZone` in the config), whatever the tablet is set to.
`{ type: 'clock', seconds: false, hour12: <locale default> }`

### `weather`
Current condition, temperature, humidity and wind, plus a forecast strip from
`weather.get_forecasts`.
`{ type: 'weather', entity: 'weather.home', days: 5, forecast: 'daily' }`. `forecast` is
`'daily'`, `'hourly'` or `false`. Not every provider offers both.

### `calendar`
Agenda for the next `days` days, merged from several calendars, one colour each,
de-duplicated (the same title at the same start shows once). Refreshes every 5 minutes.
```js
{ type: 'calendar', days: 7, calendars: [
  { entity: 'calendar.family', color: '#69F0AE' },
  { entity: 'calendar.holidays', color: '#FFD740', skipMultiDay: true },
] }
```
Wants height: give it `size: 2` or more. It scrolls by touch if it overflows.

### `toggles`
Tiles that act on tap. The service depends on the domain:

| Domain | Tap does | Lit when |
|---|---|---|
| light, switch, fan, input_boolean, … | `homeassistant.toggle` | `on` |
| cover | `cover.toggle` | `open`/`opening` |
| lock | lock ↔ unlock | `unlocked` |
| scene, script | `turn_on` (momentary: the tile flashes) | never |
| button, input_button | `press` (momentary) | never |

```js
{ type: 'toggles', columns: 3, items: [
  { entity: 'light.living', name: 'Living', icon: 'sofa',
    value:  { entity: 'sensor.living_temperature', decimals: 1 },  // under the icon
    corner: { entity: 'sensor.living_remote_battery' } },          // top-right
] }
```
`value` and `corner` take `{ entity, attribute?, decimals?, unit? }`. Without an
icon, one is picked per domain/device class. A tap that couldn't reach HA
(socket down) flashes the tile border red.

### `climate`
Thermostat/AC tiles: mode icon, `current° / target°`, tap toggles on/off,
− and + in the top corners nudge the setpoint by the entity's `target_temp_step`.
Taps are debounced (1.2 s) into **one** `set_temperature` call; cloud AC
integrations throttle anything chattier. Heating glows in `--warn`.
`{ type: 'climate', columns: 2, items: [{ entity: 'climate.living', name: 'Living' }] }`

### `sensors` and `energy`
Read-only value tiles. Same options, different default: `energy` items default
to `today: true`.

```js
{ type: 'energy', columns: 3, items: [
  { entity: 'sensor.grid_import_total', name: 'Power', icon: 'flash', warnAbove: 15 },
  { entity: 'sensor.gas_total', name: 'Gas', icon: 'fire', decimals: 2 },
  { entity: 'sensor.power', name: 'Now', icon: 'gauge', today: false, decimals: 0,
    warnAbove: 2000, dangerAbove: 4000 },
] }
```

| Option | Meaning |
|---|---|
| `today` | show `current − value at local midnight`. For lifetime counters only. |
| `attribute` | read an attribute instead of the state |
| `decimals`, `unit` | formatting; unit defaults to the entity's own |
| `warnAbove/Below`, `dangerAbove/Below`, `okAbove` | colour the value: warn → `--warn`, danger → `--danger`, ok → `--ok` |

The midnight baseline is fetched from the history API at load and re-fetched
after every midnight. A baseline that can't be a real reading (≤ 0, or above the
current value) blanks the tile rather than showing a lifetime total as "today".
That case is explained in [gotchas.md](gotchas.md).

### `media`
One player: artwork, title, artist, previous / play-pause / next, volume ±.
`{ type: 'media', entity: 'media_player.kitchen', name: 'Kitchen' }`

### `status`
"What needs attention": a chip per item that is *active* (open, on, detected,
home); an all-clear line when there is none. `showAll: true` shows every item,
lit when active (good for people). Doors, windows and motion light in `--warn`; people
light in `--accent`.
`{ type: 'status', title: 'Doors', showAll: false, emptyText: 'All shut', items: [{ entity, name, icon, activeStates }] }`

`activeStates` replaces the built-in "active" states for entities with their own
vocabulary. That's how appliances work:

```js
{ type: 'status', emptyText: 'Nothing running', items: [
  { entity: 'sensor.washer_machine_state', name: 'Washer', icon: 'washing-machine', activeStates: ['run', 'pause'] },
  // the same entity twice: one chip while it runs, one when it's done
  { entity: 'sensor.dishwasher_operation_state', name: 'Dishwasher', icon: 'dishwasher', activeStates: ['delayedstart', 'run', 'pause'] },
  { entity: 'sensor.dishwasher_operation_state', name: 'Empty dishwasher', icon: 'dishwasher', activeStates: ['finished'] },
] }
```
Pick the states from the entity's `options` in `inventory.json`.

## Layout

```js
columns: [
  { width: 1,   panels: [ { type: 'weather', size: 1, … }, { type: 'climate', size: 1, … } ] },
  { width: 1.2, panels: [ { type: 'clock', size: 1 }, { type: 'calendar', size: 2, … } ] },
  { width: 1,   panels: [ … ] },
]
```

`width` and `size` are relative (CSS `fr`). Rules of thumb, for a measured
viewport `W × H` in CSS px:

- **Columns:** 3 for 16:10 landscape (1280×800, 1920×1200), 2 for 4:3 or
  portrait, 4 only above ~2400 px wide.
- **Tile width ≥ ~120 px** (column width ÷ `columns`). Tile names and values
  shrink to fit their tile (down to 65 %, then an ellipsis), but below that width
  the icons feel cramped too.
- **Tile height ≥ ~150 px** for a tile panel's share of the column. If a column has four
  tile panels on an 800 px screen, it's too much.
- **Calendar** wants the tallest slot. **Clock** reads well at size 1 of 3.
  **Weather** needs about 1/3 of a column for the forecast strip.
- **Text size:** everything scales from one unit (`--u`, about 1 % of the viewport
  height on 16:10). `scale` in the config multiplies it: `1.2` for a room-wide view.

All tracks are `minmax(0, …fr)`, never plain `fr`. That's what keeps a panel
inside its slot instead of pushing the page taller than the screen. Keep it that
way in any new CSS (see [gotchas.md](gotchas.md)).

## A second page

A second layout (a phone in landscape, a small hallway screen) is a second HTML
page next to `index.html`. Copy `index.html` to `phone.html`, and have it import a
second boot module that loads `dashboard.phone.config.js`, or factor `boot()` to
take the config as a parameter. Literal imports only; the deploy stamps every
top-level `*.html` page.

### A phone page as an installed app

The phone page can be installed as an Android app (Chrome → Install app), which
opens full-screen from a home-screen icon. Chrome only offers that on **HTTPS**, so
it needs a secure origin for HA itself: the Tailscale app's `serve` mode
(tailnet-only, real certificate) works well; a plain `http://` LAN address never
qualifies. What it takes:

- A manifest linked from the page (`<link rel="manifest">`): `id` and `start_url`
  set to the page, `scope` set to the dashboard folder, `display: standalone`,
  `orientation: portrait`, and 192 and 512 px PNG icons (the 512 also as
  `maskable`, with the artwork inside the central 80 %).
- A service worker with a `fetch` handler, scoped to the dashboard folder. The
  cache-bypassing worker the dashboard already uses qualifies.
- A `wss://` WebSocket URL when the page is on HTTPS: derive it from
  `location.protocol`, never hardcode `ws://`.
- Check with CDP `Page.getInstallabilityErrors` (empty list = installable).

The token warning in [deploy.md](deploy.md) applies with extra force: keep the
HTTPS name private to the tailnet (Tailscale `serve`, never `funnel`).

**Portrait sizing:** a phone in portrait gives each tile roughly 120 px square,
far smaller than the tablet. Instead of a separate set of px sizes, make each tile
a size container (`container-type: size`) and set the size tokens on the page as
`min(<n>cqmin, <tablet px>)`, e.g. `--font-sm: min(11cqmin, 20px)`. A custom
property holding `cqmin` is resolved where it is *used*, against the nearest
container, so one token set scales every tile, and the px cap leaves larger
screens as they were. Scale the fixed-px parts inside tiles (bar heights, small
icons) the same way.
