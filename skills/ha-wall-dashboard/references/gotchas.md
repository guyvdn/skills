# Gotchas

Each of these was hit on a real wall dashboard, and most cost an evening.
The starter already handles all of them. This file is here so nobody undoes the
handling while "cleaning up", and so new panels don't reintroduce them.

## Network and origin

- **Same origin or nothing.** The app calls `location.origin` for REST and
  `ws(s)://location.host/api/websocket`. A hardcoded IP worked on the PC and
  failed on the tablet, which loaded the page via `homeassistant.local`: the browser
  saw a cross-origin call and blocked it. The symptom was a permanent "no connection".
- **Third-party APIs called from the browser are usually CORS-blocked.** A
  waste-collection backend rejected every browser preflight. Fetch such data
  through an HA integration (server-side) and read the resulting entity instead.
- **Half-open WebSockets.** Wifi drops can leave a socket that never fires
  `onclose`, and the dashboard then shows frozen values with no error. The 30 s
  ping/pong heartbeat in `connectLive` is what catches it. Keep `heartbeatMs` on.
- **Bad token = stop.** On `auth_invalid` the client stops reconnecting. Retrying
  in a loop gets the tablet's IP banned by HA's `ip_ban_enabled`.

## Caching

- **`/local/` is cached for 31 days**, and a kiosk browser can't hard-refresh.
  Hence the self-busting `index.html`, the deploy-time `?v=` stamps, and
  `assetUrl()`. All three are needed; see [deploy.md](deploy.md).
- The self-bust checks the **age** of `?v=`, not the navigation type. Fully Kiosk
  restores its last URL (with an old `?v=`) as a normal navigation.
- **Literal relative imports only.** A dynamic `import(\`./panels/${type}.js\`)` is
  invisible to the stamp, so the panel registry imports everything statically.
- A **service worker** looks like the fix, but browsers only run them on https or
  localhost. On a plain-http LAN it is silently inert.

## Data from Home Assistant

- **History API: `significant_changes_only=false`, always.** With `true`, HA
  strips most entries. For some domains (climate) it returned *zero* rows over 30 days
  of real data.
- **Recorder retention is ~10 days** by default; history further back is empty.
- **HA back-fills the last known state** into a history window, but only if the
  entity had *some* state before the window. A brand-new sensor has no midnight
  baseline on day one: blank, not wrong.
- **A baseline can be present and still be garbage.** A cloud integration lost an
  appliance and parked its energy counter at `-0.001` for six days. Midnight fell
  in that window, so "today" showed the whole lifetime total (`246.8 kWh` for a
  dryer). `todayDelta` rejects baselines ≤ 0 or above the current value. One blank
  day after a genuine counter reset is the price, and it's worth paying.
- **Per-cycle counters reset to 0** when an appliance stops. Use the lifetime
  (`total_increasing`) counter for "today", never the per-cycle one.
- **Stale integration ≠ dashboard bug.** A tile lit with a finish time hours in the
  past, twice, was a cloud integration whose subscription died mid-cycle. Check
  `last_reported` in HA before touching formatting code. Reloading the integration fixes it.
- **Timestamp formats vary by integration and even by state.** One reported ISO while
  running and `MM/DD/YYYY` while stopped; a 3D printer reports `DD/MM/YYYY`. Write
  a parser test per integration before trusting a format.
- **`unavailable` / `unknown` are states, not errors.** Every paint path must render
  them as `—`, never `NaN`, `0` or a crash.
- **Music Assistant** reports `media_content_id` in its `library://…` form even
  when you started playback with a provider URI. Compare against the library id,
  or an "is this station playing" highlight never matches.
- The weather forecast **left the entity attributes in HA 2024.3**. It comes from
  `weather.get_forecasts` with `return_response`.

## Layout and CSS

- **`minmax(0, 1fr)`, never plain `1fr`, for any track that holds tiles or
  panels.** `1fr` keeps a min-content floor. Tiles (icon + 3 text rows) were taller
  than their cells and overflowed: 370 px tiles in 280 px cells, a 756 px climate grid
  in a 600 px slot.
- **A tile needs `grid-template-columns: minmax(0, 1fr)`**, or its single column
  shrinks to content width and the corner items float in from the edges.
- **`el.hidden = true` doesn't hide an element whose CSS sets `display`.** Author
  CSS beats the UA `[hidden]` rule. Use `el.style.display = 'none'`.
- **A unit inside a flex container centres instead of sitting on the baseline.**
  Keep value + unit spans out of `align-items: center` flex boxes.
- **SVG `<text>` ignores `vertical-align`.** Raise a degree sign with a `<tspan dy>`.
- **CSS `text-transform: capitalize` capitalises month names**, which is wrong in Dutch,
  French and German. Capitalise the first letter in JS instead.

## Touch and the tablet

- **Pointer-only long-press dies on Android WebView** at ~500 ms (`pointercancel`).
  A separate `touchstart` path with `preventDefault` and `{ passive: false }` is needed.
- **Colours differ on the device.** Deep orange looked brown on the tablet. Judge on the
  wall, never from a desktop screenshot.
- **The real viewport is not the panel resolution**, and changes when the kiosk
  app hides its bars. Measure with `measure.html` after every kiosk-settings change.

## Windows-specific

- A folder named **`icons`** on an HA Samba share: the Windows shell intercepts
  that name on UNC paths, and copies fail silently. The starter uses `core/icons.js`
  (a file, fine) and no `icons/` folder. Keep it that way.
- PowerShell 5's `Get-Content`/`Set-Content` default to the ANSI code page and
  mangle `°`, `³`, `—`. The Node deploy script avoids that. If you ever script file
  edits in PowerShell, use explicit UTF-8.
