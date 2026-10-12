# Themes

A theme is a block of CSS custom properties in `www/style.css`, selected by
`data-theme` on `<html>`. Components only ever use the tokens, so a theme
never needs component CSS.

## The five built-in themes

| Theme | Background | Accent | Type | Corners | Glow |
|---|---|---|---|---|---|
| `tron` | navy radial, glass cards | cyan `#00E5FF` | Share Tech | rounded | cyan neon |
| `synthwave` | violet gradient | hot pink `#FF2E97` | Share Tech Mono | slightly rounded | pink neon |
| `nord` | flat `#2E3440` | frost `#88C0D0` | system UI | rounded | none |
| `amber` | black, CRT scanlines | amber `#FFB000` | Share Tech Mono | square | amber |
| `daylight` | light grey, white cards | blue `#0A84FF` | system UI | rounded | none |

Choose on the **tablet**, using `themes.html` (deployed with the dashboard):
real panels, fake data, a button per theme; taps work so the "on" state can
be judged too. `?theme=nord` opens one directly; `?scale=1.2` tries a size.

## Config options

```js
theme: 'nord',                                  // fixed
theme: { day: 'daylight', night: 'tron' },      // follows sun.sun (above_horizon = day)
themeOverrides: { '--accent': '#7CFFB2' },      // any token, inline
scale: 1.15,                                    // all sizes
```

Use overrides for "the same, but green"; write a new theme when more than
three or four tokens change.

## Tokens

| Token | Used for |
|---|---|
| `--bg` | page background (any CSS background) |
| `--font`, `--font-mono` | body type; tabular things like calendar times |
| `--accent` | **normal / active**: lit tiles, active icons |
| `--accent-soft`, `--accent-dim` | secondary accent: date, forecast rain %, sensor icons |
| `--warn` | **needs attention**: open door, heating, threshold crossed |
| `--danger` | **something is wrong**: auth failed, failed tap, danger thresholds |
| `--ok` | good news: all clear, `okAbove` thresholds |
| `--text`, `--text-2`, `--text-dim` | primary, secondary, idle/inactive |
| `--card-bg`, `--card-on-bg` | card and tile fill; fill of a lit tile |
| `--card-border`, `--card-on-border`, `--border-w` | borders |
| `--radius`, `--shadow`, `--blur` | shape; `--blur` > 0 gives frosted glass |
| `--glow` | a CSS `filter` on lit icons: `drop-shadow(...)` or `none` |
| `--title-case`, `--title-spacing` | `uppercase` + wide tracking for a technical look |

## Making a new theme

1. Copy the closest block in `style.css`, rename the selector to
   `[data-theme="<name>"]`, and change the tokens.
2. Add the name to `THEMES` in `themes.html`.
3. Check it in `themes.html` **on the tablet**, in a lit room and in a dark one.
4. Record it in `DASHBOARD.md` → Look.

A theme local to one project is a local edit. `scaffold --upgrade` will then keep
the user's `style.css` and list it as edited. Fine, just mention it.

## Colour rules that came from a real wall

- **Colour means state, not decoration.** One accent for "normal/on", one
  colour for "attention", one for "broken". If the danger red appears in normal use,
  it stops meaning anything. On the original dashboard red appears only when the
  connection is lost.
- **Cheap tablet panels have a narrow gamut.** Deep orange (`#FF7200`) rendered
  as *brown* on the original tablet. The amber `#FF8800` has enough yellow to survive.
  Mid-dark greys crush to black, and saturated blues go purple. Always judge on the device.
- **Calendar colours must not match the accent.** A yellow birthday calendar
  disappears in `amber`, and a cyan one in `tron`. Pick per-calendar colours from
  hues the theme doesn't use. Revisit them when the theme changes.
- **Idle icons must be dim** (`--text-dim`) so lit ones stand out at a glance.
  A tile that inherits the bright text colour while off looks "on" from across the room.
- **Contrast for the light theme**: `--warn` has to be darker on white
  (`#D97000`, not `#FF8800`), or warnings vanish in daylight.
- **Glow is a filter on the icon**, `drop-shadow` on a transparent SVG, so it hugs
  the shape. A `box-shadow` glow on the tile reads as a rectangle and looks cheap.
- Burn-in: a static bright layout on an OLED panel will burn in. Dark themes and
  dimming at night help (see [kiosk.md](kiosk.md)).

## Fonts

`Share Tech` and `Share Tech Mono` (SIL Open Font License) ship in `www/fonts/`
and are self-hosted, so the wall never depends on an external font CDN. To use
another font, add the `.woff2` to `fonts/`, add an `@font-face` at the top of
`style.css`, and reference it in the theme's `--font`. Check its licence allows
self-hosting.
