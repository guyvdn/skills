# Deploying to Home Assistant

The dashboard is static files in HA's `config/www/<name>/`, which HA serves at
`/local/<name>/`. No add-on, no integration, no HACS, no restart per deploy.

## Getting write access to `config/www`

Find out which of these the user already has. Ask before installing anything.

| Install type | Easiest route | Deploy target as seen from the PC |
|---|---|---|
| HA OS / Supervised | **Samba share** add-on | Windows `\\homeassistant.local\config\www\<name>` · macOS `/Volumes/config/www/<name>` after Finder → Go → Connect to Server `smb://homeassistant.local` |
| HA OS / Supervised | SSH & Web Terminal / Advanced SSH add-on | deploy to a local folder, then `scp -r` it. Or mount with `sshfs`. |
| Container / Core | the host's own filesystem | the bind-mounted config dir, e.g. `/srv/homeassistant/config/www/<name>`. Over the network: a share or `sshfs`. |
| any | Studio Code Server / File editor add-on | manual upload only. Workable for a first test, painful for iteration. |

`deploy.mjs` copies to any path this machine can write, and refuses targets that
aren't directly under a `www` folder. Prefer **forward slashes** for shares
(`//homeassistant.local/config/www/wall`). Windows accepts them, and backslashes
get eaten by shells: Git Bash turns a quoted `\\host\share` into `\host\share`.
The scripts repair that common case, but don't rely on it.

**First time `www` exists:** HA only registers `/local/` if `config/www` existed
at startup. If the folder is new, the user must **restart HA once**
(Settings → System → Restart). After that, never again for deploys.

**Windows + Samba gotchas:**
- Open the share once in Explorer first. That stores the credential and opens
  the session; scripts then just work. Hardened Windows clients refuse guest access,
  so the add-on needs a username and password set.
- Never name a folder on the share `icons`. The Windows shell treats that
  name specially on UNC paths, and copies into it fail silently.

## The token, and the tablet's HA user

`www/config.local.js` holds a long-lived token. It's gitignored, but it's
**served**: anyone on the LAN who knows `/local/<name>/config.local.js` can read
it. `/local/` has no authentication. That's the accepted trade-off for a private
home LAN. Say it plainly, once, during setup, and:

- Create a **dedicated HA user** for the tablet (Settings → People → Users → Add,
  "Can only log in from the local network" on, admin off if the panels allow it).
  Its token can be revoked without touching the user's own login, and HA's logbook
  then tells the tablet's taps apart from the person's phone.
- If HA is exposed to the internet (Nabu Casa, reverse proxy), `/local/` is exposed
  too. Then the token in that file is reachable from outside. Strongly prefer
  the dedicated non-admin user in that case. Consider whether the dashboard
  should only be reachable on the LAN.
- **Never** put the token in the chat, a commit, or a file outside `config.local.js`.

Non-admin users can read states, call services, read history and calendars,
which covers everything the panels do. Discovery needs admin (registries), so
run discovery with the user's own admin token via `HA_TOKEN`, and give the tablet
the non-admin one.

## What `deploy.mjs` does

1. Refuses without `config.local.js` (placeholder included) and `dashboard.config.js`,
   and refuses any target that, once resolved, isn't directly inside a `www` folder.
2. **Refuses an admin token** in `config.local.js`: it asks HA who the token
   belongs to (`auth/current_user`). `--allow-admin` overrides it; only for a short,
   LAN-only test the user explicitly accepted. If HA can't be reached it warns and deploys.
3. Copies `www/` except `tests/`, `*.example.js`, `*.orig`, `package.json` and dotfiles.
4. Stamps `?v=<timestamp>` on every relative `from './x.js'`, bare `import './x.js'`
   and literal `import('./x.js')`, and on the
   `style.css` link **in the deployed copy**. Source files stay clean.

`--dry-run` lists what would be copied.

Old files are not deleted from the target. A removed panel module lingers
harmlessly; clean up by hand if it matters.

## Why the cache-busting is not optional

HA serves `/local/` with `Cache-Control: max-age=2678400`: **31 days**. A kiosk
browser has no hard-refresh. Without stamping, the tablet runs month-old code
next to new code: a mix that fails in confusing ways. Three layers handle it:

1. `index.html` redirects itself to `?v=<now>` unless its `?v=` is under 10 s
   old, so the HTML is always fresh. The check is by age, **not** by navigation
   type: Fully Kiosk restores its last URL, old `?v=` included, as a normal
   navigation, which a navigation-type check mistakes for its own redirect.
2. The deploy stamps every JS import and the stylesheet, so fresh HTML pulls fresh code.
3. Runtime-built URLs (an image path assembled in JS) are invisible to the
   stamping. Wrap them in `assetUrl()` from `core/asset-version.js`, which reuses
   the deploy stamp.

Rules that follow: **literal relative imports only** (no `import()` of a computed
path, no bare specifiers), and **every page is a top-level `*.html`**.

## After deploying

1. Reload the tablet. Fully Kiosk: pull-down refresh, or Remote Admin → Reload.
2. Check the connection pill is gone (bottom-left; shown only when disconnected).
3. A panel that shows dashes: run `check-config.mjs`. A panel that says it failed:
   open the page on a PC, look at the console.
