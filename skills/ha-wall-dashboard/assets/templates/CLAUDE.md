# {{NAME}} — wall dashboard

A Home Assistant wall-tablet dashboard built from the `ha-wall-dashboard` skill.

- **Load the `ha-wall-dashboard` skill** at the start of any session in this repo.
- **Read `DASHBOARD.md` first.** It records this home's hardware, the entity
  choices and every quirk found so far. Update it whenever you learn something
  non-obvious — a renamed entity, an integration that misbehaves, a design decision.
- The dashboard is `www/`. Its home-specific settings are all in
  `www/dashboard.config.js`; prefer changing the config over changing code.
- Before deploying: `node --test www/tests/*.test.mjs` and the skill's `check-config.mjs`.
- `www/config.local.js` holds the HA token. Never commit it, never print it.
