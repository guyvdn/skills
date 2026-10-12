# Maintaining a running dashboard

Start every maintenance session by reading the project's `DASHBOARD.md`, and end
it by updating it. The loop for any change:

```
edit www/dashboard.config.js (or code)
  → node <skill>/scripts/check-config.mjs --project .
  → node --test www/tests/*.test.mjs
  → node <skill>/scripts/deploy.mjs --project .
  → user reloads the tablet and looks
```

## Common changes (config only)

| Request | Change |
|---|---|
| "Add the garden lights" | new item in the `toggles` panel. Short `name`, `icon`. |
| "That tile shows a dash" | `check-config`. Usually a renamed entity or an `unavailable` integration. Fix the id, or the integration in HA. |
| "Move the calendar left" | move the panel object between `columns[].panels` |
| "The calendar needs more room" | raise its `size`, or the column's `width` |
| "Everything is too small" | `scale: 1.2` |
| "Different colour" | `themeOverrides: { '--accent': '#…' }`, or another theme |
| "Dark at night, light by day" | `theme: { day: 'daylight', night: '<dark theme>' }` |
| "Use Dutch / French / German" | `locale: 'nl-BE'` etc. Built-in strings exist for en/nl/fr/de; other languages via `labels`, or add a block to `core/i18n.js`. |
| "Warn me when power is over 3 kW" | `warnAbove: 3000` on that sensor item |
| "Show today's water use" | `energy` item on the lifetime water counter |

## New entities in HA

After the user adds a device or integration, re-run `discover.mjs`, and look at the
group the new entity landed in. Re-paired devices often come back as
`light.kitchen_2`; `check-config` flags the old id as missing. Update the config,
and note the rename in `DASHBOARD.md` → Quirks.

## New panel types (code)

When the catalogue genuinely lacks something (a car tile with a battery bar,
a printer's progress, a waste-collection countdown):

1. **Pure logic first**, in `www/panels/logic.js` or a new `www/panels/<type>-logic.js`:
   functions from state objects to a view model, with no DOM. Write tests in
   `www/tests/`. This is where the bugs live (date formats, units, edge states),
   and `node --test` makes them cheap to catch.
2. **The panel module** `www/panels/<type>.js`:
   ```js
   export const card = true;               // glass card around it? false for tile grids
   export function render(el, cfg, ctx) {  // el = the panel body, cfg = its config object
     // ctx: { store, client, token, baseUrl, locale, t, config }
     ctx.store.subscribe([cfg.entity], (s) => { /* paint from s; s may be null */ });
   }
   ```
   Reuse `createTile` / `createTileGrid` (`core/tile.js`) for tiles so they align
   with the rest, `setWithUnit` for value + unit, `iconSvg` for icons,
   `fetchMidnightValue` + `todayDelta` for "today" values.
3. **Register it** in `www/panels/registry.js` with a static import.
4. **Style it** in `style.css` with theme tokens only, no literal colours, so every
   theme works. Add a sample to `themes.html` if it has a distinctive look.
5. Document its config in the project's `DASHBOARD.md`. It's local to this home.

Painting rules: every subscription callback must cope with `null` (not loaded
yet) and with `unavailable`. Show `—` rather than `NaN` or `0`. Never let one
panel throw into another (the layout isolates `render`, but async callbacks
must catch their own errors).

Services: `ctx.client.callService(domain, service, target, data)` (returns
`false` when offline, so show it). Services that return data:
`await ctx.client.callServiceForResponse(...)`. Any other WS command:
`await ctx.client.request({ type: '...' })`.

## Upgrading to a newer starter

When this skill gets improvements:

```
node <skill>/scripts/scaffold.mjs --to <project> --upgrade
```

Starter files the user never touched are replaced. Files they edited are
**kept** and listed: diff each against `<skill>/assets/starter/<file>`, merge
by hand, then run the tests. `--force` replaces edited files too, saving each
local version next to it as `<file>.orig` (not deployed) so nothing is lost.
`dashboard.config.js` and `config.local.js` are never touched. A new config option
in the upgrade is opt-in. Mention it, don't apply it unasked.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| "Connection lost" pill forever | page not same-origin with HA; HA down; proxy blocks WebSockets | open the dashboard URL on a PC, console; [kiosk.md](kiosk.md) → Same origin |
| "Login failed" pill | token revoked or mistyped. HA also **bans the IP** after repeated failed logins (`ip_bans.yaml`). | new token; check HA's log for bans |
| Every panel blank, no pill | JS error at load, often a syntax error in `dashboard.config.js` | console on a PC; `check-config --offline` |
| One panel says it failed | exception in that panel's `render` | console; usually a missing config key |
| A tile shows `—` | entity renamed, removed or `unavailable` | `check-config` |
| A tile shows a stale value with no error | the **integration** is stale, not the dashboard. Cloud devices drop their subscription and freeze mid-value. | the entity's `last_reported` in HA Developer Tools → States; reload the integration in HA |
| "Today" energy shows a huge number | baseline from a day the meter reported garbage | already guarded against by `todayDelta`. If it still happens, the counter isn't really monotonic: use a `utility_meter` helper in HA with `today: false` |
| "Today" tile blank on a new sensor | no history before midnight yet | fills in from the next day |
| Change deployed but tablet shows old | stamping bypassed: a dynamic import, a non-relative import, or a runtime-built URL without `assetUrl()` | [deploy.md](deploy.md) → cache-busting |
| Weather forecast strip empty | provider has no `get_forecasts` for that type | try `forecast: 'hourly'`, or another weather integration |
| Calendar empty but HA shows events | events outside the `days` window, or `skipMultiDay` filtered them | calendar config |
| Layout taller than the screen, cut off | a new grid track with plain `1fr` | use `minmax(0, 1fr)`; [gotchas.md](gotchas.md) |
| Lights toggle by themselves | ghost touches from the charger | [kiosk.md](kiosk.md) → Touch; HA logbook shows which user toggled |
