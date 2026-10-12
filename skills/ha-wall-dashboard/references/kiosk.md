# The tablet

## Hardware notes

- Any Android tablet from the last few years works; the page is light. Budget
  tablets are fine but have narrow colour gamuts (see [themes.md](themes.md)).
- **Power:** on a charger 24/7, a lithium battery swells within a year or two.
  Use the tablet's own "battery protection" or 80 % charge-limit setting if it has one,
  or a smart plug with an HA automation that cycles charging between 30 and 80 %.
- Mount at eye height, out of direct sunlight (glare beats any theme).

## Browser: Fully Kiosk Browser (Android)

The usual choice; the PLUS licence is worth it for motion/screen control and
remote admin. Settings that matter:

| Setting | Value | Why |
|---|---|---|
| Start URL | `http://<ha-host>:8123/local/<name>/index.html` | **same host and port as the HA API**, see below |
| Web Content → Autoplay videos | on | media artwork / any video |
| Web Zoom → Enable zoom | off | pinch would wreck the layout |
| Web Auto Reload → on network reconnect | on | belt and braces with the app's own reconnect |
| Fullscreen → Hide status bar, navigation bar | on | then re-run `measure.html`, the size changes |
| Device Management → Keep screen on | on, or use motion/schedule below | |
| Screensaver / Screen off timer | per taste | e.g. dim at night via Fully's REST or the HA Fully Kiosk integration |
| Remote Administration | on, with a password | reload the page from a PC without touching the wall |

Fully Kiosk has an **HA integration** (Settings → Devices & services → Add →
Fully Kiosk Browser). It exposes screen on/off, brightness, the camera's motion
detection and the battery level. "Screen on when someone walks past, off at night"
then becomes an ordinary HA automation.

Other browsers: any Chromium-based kiosk works. iPad: Safari + Guided Access
works but can't keep the screen on reliably; use "Add to Home Screen" for
fullscreen. Measure again after any change.

## Same origin: the one rule

Open the dashboard on **exactly** the host and port the HA API is on, e.g.
`http://homeassistant.local:8123/...` or `http://192.168.1.10:8123/...`.
The app derives the API from the page's own origin, so it works under any name.
But a page served from elsewhere (a NAS, `python -m http.server`, port 8000) is
cross-origin and HA blocks the calls ("Connection lost" forever). If HA is on
https, open the dashboard over https.

## Measuring

`measure.html` shows the CSS viewport. That's the size the layout really gets,
which is almost never the spec-sheet resolution (a 2560×1600 panel at
devicePixelRatio 2 is 1280×800). The cyan frame should touch all four edges. A
missing side means a system bar overlaps the page.

## Time zone

The clock, the calendar's "today/tomorrow" and every "today since midnight"
value use the **tablet's** time zone, not HA's. Cheap tablets often ship set to
UTC, so the energy tiles then reset at 01:00 or 02:00 local time and the clock is off.
`measure.html` shows the tablet's zone. Compare it with `ha.timeZone` in
`inventory.json`, and fix it in Android's date settings if they differ.

## Touch

- Tap targets ≥ ~48 CSS px. The climate ± buttons and media buttons are sized
  from the viewport unit for this reason; don't shrink them.
- **Long-press is a trap on Android WebView.** The WebView starts its own long-press
  (text selection / context menu) at ~500 ms and fires `pointercancel`, which kills any
  pointer-event long-press timer. If a new feature needs a hold gesture, it needs a
  separate touch path: `touchstart` with `preventDefault()` registered
  `{ passive: false }`, `touch-action: none` on the element, and pointer handlers
  that ignore `pointerType === 'touch'`. Works with a mouse ≠ works on the wall.
- **Ghost touches:** a tablet on a charger with a poor ground can register phantom
  taps, so lights toggle by themselves. If HA's logbook shows toggles nobody made,
  try a different charger/cable before suspecting the code. The dedicated
  tablet user (see [deploy.md](deploy.md)) makes these show up clearly in the logbook.

## Testing without the tablet

Playwright (or any browser) at the measured size, against the deployed URL, is
good for layout regressions (`scrollHeight − innerHeight` should be 0) and for
console errors. It is **not** a substitute for looking at the wall: colour, glare,
type size at distance and touch all need the real device. Hand visual changes
back to the user to eyeball.
