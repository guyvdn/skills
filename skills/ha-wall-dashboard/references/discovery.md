# Discovery: from `inventory.json` to a shortlist

`discover.mjs` reads states plus the entity, device and area registries over
the WebSocket, and writes `inventory.json`:

| Key | Contents |
|---|---|
| `ha` | version, location name, time zone, language, country, unit system |
| `areas` | area names. Use them to group proposals per room. |
| `counts` / `candidates` | per panel-relevant group, the usable entities with name, area, current state, unit, integration (`platform`). Enum sensors also list every state they can report (`options`), and calendars carry `upcoming30d`, their event count for the next 30 days. |
| `entities` | everything usable, flattened. Grep this when a group misses something. |
| `registryAvailable` | `false` = the token isn't an admin's: no areas, no diagnostic filtering |
| `sunAvailable` | `sun.sun` exists, so the day/night theme switch can work |

By default it skips entities that are `unavailable`/`unknown`, hidden, or
in the `diagnostic`/`config` category. `--all` keeps them, which is useful when the user
says "but I *have* a sensor for that".

The groups are heuristics. **Expect to clean them up before proposing anything.**

## Cleaning up, group by group

**weather.** Often two (`weather.home` and `weather.forecast_home`), both from Met.no.
They're the same data; pick the one in `ha.location`'s name or the one the user uses.
Weather providers without a forecast service still work, but the strip stays empty.

**calendar.** Personal calendars, shared family ones, holidays, birthdays, waste
collection, sometimes a dozen subscribed sports fixtures. Ask *whose* calendars belong on a
family wall. Work calendars usually don't, unless the user wants them. Waste-collection
integrations often provide a calendar too; that's a nice addition to the agenda.

**lights.** Includes room groups, single bulbs, *and* plugs that Hue or IKEA expose
as lights. Prefer one tile per room (the group or the area's main light). A light whose
name ends in `_2` or `_3` is often a duplicate from a second integration (e.g. Hue
bridge plus Matter) or a leftover from a re-pairing: check which one has
recent `last_changed` in `entities`.

**switches.** Mixed bag: real wall plugs, but also integration settings that
weren't categorised (a car's "window heating", a dishwasher's "power"). Only
propose things a person would deliberately flip on a wall.

**locks_covers / scenes_scripts.** Locks and garage doors on a wall tablet are a
security question: anyone in the hallway can tap them. Mention it; let the user decide.
Scenes and scripts make great "one tap" tiles ("Movie", "Good night").

**climate.** Thermostats, AC units, TRVs, and also cars' pre-conditioning
(`climate.<car>_air_conditioning`). Leave the car out unless asked. Cloud-polled AC
units (Daikin, Mitsubishi, Tado) rate-limit: the panel debounces setpoint taps for this reason.

**media.** Usually inflated: every Cast device, every group, plus Music
Assistant's mirror players (`media_player.kitchen`, `media_player.kitchen_2`, `…_3`).
The MA one is normally the one that reports what's playing correctly; check `state`
and `media_title` in `entities` while something plays.

**energy_counters.** Lifetime counters (`total_increasing`): grid import/export,
gas, water, and also per-device counters and utility-meter helpers (`daily_*`,
`monthly_*`). For a "today" tile, use the **lifetime** counter with
`today: true` (default for `energy`). A `daily_*` utility meter already resets at
midnight, so use it with `today: false`. Don't stack both.

**power_now.** Live watts. The main meter's `*_power` is the useful one. Phase
and peak sensors are rarely wall material.

**temperature / humidity / air_quality.** Good as the small value line on a
light tile (`value:` in [panels.md](panels.md)) rather than tiles of their own.
Outdoor readings from AC units read high or low depending on where the unit hangs.
Prefer the weather entity for outdoors.

**doors_windows / motion.** Will include a car's doors, bonnet and windows, and
every motion sensor. For the status panel, propose the house's exterior doors,
plus windows only if there are few.

**people.** `person.*`. With `showAll: true` the status panel shows everyone,
lit when home.

**appliances / vehicles.** Pattern-matched, so they're noisier than the rest. A
washer's or dryer's `machine_state` is an enum (`run`, `pause`, `stop`): show it as a
`status` chip with `activeStates` taken from its `options`. A car's battery level
and range fit a `sensors` panel. For timestamps (finish times), use a `sensors` tile with an
attribute or a template sensor in HA. The starter has no timestamp formatting
(see "New panel types" in [maintain.md](maintain.md) if the user wants one).

## Things discovery can't see

- **What the user cares about.** Ask what they look at every morning; that's the wall.
- **Integrations that are configured but unreliable.** Ask "anything that's often
  wrong or offline?" and note it in `DASHBOARD.md`.
- **Template sensors are often the answer.** If a panel needs a value HA doesn't
  have yet ("is any window open", "minutes until the dishwasher is done"), a
  template sensor or group helper in HA is cleaner than logic in the dashboard.
  Suggest it; the user creates it in the HA UI (Settings → Devices & services →
  Helpers). This skill does not edit HA configuration.

## Re-running later

Discovery is cheap. After the user adds integrations, re-run it and diff the
`counts`, or run `check-config.mjs`, which lists configured entities that disappeared
(renamed or re-paired devices are the usual cause).
