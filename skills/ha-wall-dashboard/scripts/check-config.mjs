#!/usr/bin/env node
// Validate www/dashboard.config.js against the live Home Assistant: every
// entity id exists and is reporting, every panel type and icon is known.
// Read-only. Run it before every deploy and after HA integration changes.
//
//   node check-config.mjs --project <dir> [--url http://ha:8123] [--offline]
//
// --offline skips the HA lookup and only checks types, icons and structure.
// Exit code 1 when something is wrong, so it can gate a deploy.
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { resolveConnection, restGet, fail } from './lib/ha.mjs';

const { values: args } = parseArgs({
  options: {
    project: { type: 'string', default: '.' },
    url: { type: 'string' },
    offline: { type: 'boolean', default: false },
  },
});

const www = join(resolve(args.project), 'www');
const load = async (rel) => import(pathToFileURL(join(www, rel)).href);
let config, PANELS, ICONS;
try {
  config = (await load('dashboard.config.js')).default;
  ({ PANELS } = await load('panels/registry.js'));
  ({ ICONS } = await load('core/icons.js'));
} catch (e) {
  fail(`Could not load the config: ${e.message}`);
}

const problems = [];
const warnings = [];
const refs = []; // { entity, where, node, panel, role }

// Which domain each panel role expects. Anything else is almost certainly a
// mix-up (a sensor id in the weather panel, a light in climate).
const EXPECT = { weather: ['weather'], media: ['media_player'], climate: ['climate'], calendar: ['calendar'] };
const MOMENTARY = /^(scene|script|button|input_button)\./; // normally 'unknown' until first used

// Collect every `entity` and `icon` anywhere in a panel's config. `role` is the
// panel type for the panel's own entities and items, 'value' for nested
// value/corner specs (any domain is fine there).
function walk(node, where, panel, role) {
  if (Array.isArray(node)) { node.forEach((n, i) => walk(n, `${where}[${i}]`, panel, role)); return; }
  if (!node || typeof node !== 'object') return;
  for (const [k, v] of Object.entries(node)) {
    if (k === 'entity' && typeof v === 'string') refs.push({ entity: v, where, node, panel, role });
    else if (k === 'icon' && typeof v === 'string' && !ICONS[v]) problems.push(`${where}: unknown icon "${v}" (add it to core/icons.js)`);
    else walk(v, `${where}.${k}`, panel, ['value', 'corner'].includes(k) ? 'value' : role);
  }
}

if (!Array.isArray(config.columns) || !config.columns.length) problems.push('config.columns is empty');
(config.columns ?? []).forEach((col, c) => {
  (col.panels ?? []).forEach((p, i) => {
    const where = `columns[${c}].panels[${i}] (${p.type})`;
    if (!PANELS[p.type]) problems.push(`${where}: unknown panel type "${p.type}"`);
    if (['toggles', 'climate', 'sensors', 'energy', 'status'].includes(p.type) && !p.items?.length) problems.push(`${where}: no items`);
    if (p.type === 'calendar' && !p.calendars?.length) problems.push(`${where}: no calendars`);
    if (['weather', 'media'].includes(p.type) && !p.entity) problems.push(`${where}: no entity`);
    if ((p.items?.length ?? 0) > 9) warnings.push(`${where}: ${p.items.length} tiles — likely too small to tap on a wall tablet`);
    walk(p, where, p, p.type);
  });
});
if (typeof config.theme === 'object') refs.push({ entity: 'sun.sun', where: 'theme (day/night)' });

if (!args.offline) {
  const { haUrl, token } = resolveConnection({ url: args.url, project: args.project });
  const states = new Map((await restGet(haUrl, token, '/api/states')).map((s) => [s.entity_id, s]));
  for (const { entity, where, node, panel, role } of refs) {
    if (entity.startsWith('_local.')) continue; // synthetic, written by a panel at runtime
    const s = states.get(entity);
    if (!s) { problems.push(`${where}: ${entity} does not exist in HA (renamed? integration removed?)`); continue; }
    const domain = entity.split('.')[0];
    if (EXPECT[role] && !EXPECT[role].includes(domain)) {
      problems.push(`${where}: ${entity} is a ${domain}, but a ${role} panel needs ${EXPECT[role].join(' or ')}.*`);
    }
    if (s.state === 'unavailable' || (s.state === 'unknown' && !MOMENTARY.test(entity))) {
      warnings.push(`${where}: ${entity} is "${s.state}" right now`);
    }
    if (node.attribute && !(node.attribute in (s.attributes ?? {}))) {
      warnings.push(`${where}: ${entity} has no attribute "${node.attribute}" right now`);
    }
    const today = role !== 'value' && (node.today ?? panel.type === 'energy');
    // A utility_meter (daily_*, monthly_*) already resets itself; its midnight
    // baseline is ~0, which todayDelta rejects, so the tile would show a dash all day.
    if (['sensors', 'energy'].includes(role) && today && (s.attributes?.meter_period || s.attributes?.last_reset)) {
      warnings.push(`${where}: ${entity} already resets on its own (utility meter / last_reset) — set today: false.`);
    } else if (['sensors', 'energy'].includes(role) && today && !['total', 'total_increasing'].includes(s.attributes?.state_class)) {
      warnings.push(`${where}: today: true on ${entity}, which isn't a lifetime counter (state_class ${s.attributes?.state_class ?? 'none'}). `
        + 'Use today: false for live values and for daily_* meters that already reset at midnight.');
    }
  }
}

for (const w of warnings) console.log(`warn  ${w}`);
for (const p of problems) console.log(`FAIL  ${p}`);
console.log(`${refs.length} entity references, ${problems.length} problems, ${warnings.length} warnings${args.offline ? ' (offline: entities not checked)' : ''}`);
process.exit(problems.length ? 1 : 0);
