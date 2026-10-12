#!/usr/bin/env node
// Inventory a Home Assistant instance and sort its entities into the groups
// the dashboard panels can use. Read-only: it never changes anything in HA.
//
//   node discover.mjs --project <dir> [--url http://ha:8123] [--out inventory.json] [--all]
//
// Writes the full inventory as JSON (default <project>/inventory.json) and
// prints a short summary. --all keeps diagnostic/config/hidden/unavailable
// entities, which are skipped by default because nobody wants a tile for
// "Hue bridge firmware".
import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { resolveConnection, wsSession, restGet, fail } from './lib/ha.mjs';

const { values: args } = parseArgs({
  options: {
    project: { type: 'string', default: '.' },
    url: { type: 'string' },
    out: { type: 'string' },
    all: { type: 'boolean', default: false },
    quiet: { type: 'boolean', default: false },
  },
});

const { haUrl, token } = resolveConnection({ url: args.url, project: args.project });
let ha;
try { ha = await wsSession(haUrl, token); } catch (e) { fail(e.message); }

const [me, states, entityReg, deviceReg, areaReg, config] = await Promise.all([
  ha.request({ type: 'auth/current_user' }),
  ha.request({ type: 'get_states' }),
  ha.request({ type: 'config/entity_registry/list' }).catch(() => []),  // needs an admin user
  ha.request({ type: 'config/device_registry/list' }).catch(() => []),
  ha.request({ type: 'config/area_registry/list' }).catch(() => []),
  ha.request({ type: 'get_config' }),
]);
ha.close();

const areas = new Map(areaReg.map((a) => [a.area_id, a.name]));
const devices = new Map(deviceReg.map((d) => [d.id, d]));
const registry = new Map(entityReg.map((e) => [e.entity_id, e]));

const entities = [];
for (const s of states) {
  const reg = registry.get(s.entity_id);
  const dev = reg?.device_id ? devices.get(reg.device_id) : null;
  const a = s.attributes ?? {};
  const e = {
    entity_id: s.entity_id,
    domain: s.entity_id.split('.')[0],
    name: a.friendly_name ?? s.entity_id,
    state: s.state,
    device_class: a.device_class ?? null,
    state_class: a.state_class ?? null,
    unit: a.unit_of_measurement ?? null,
    options: Array.isArray(a.options) ? a.options : null, // enum sensors: every state it can report
    area: areas.get(reg?.area_id ?? dev?.area_id) ?? null,
    device: dev ? (dev.name_by_user ?? dev.name) : null,
    platform: reg?.platform ?? null,
    category: reg?.entity_category ?? null,
    hidden: !!reg?.hidden_by,
    last_changed: s.last_changed,
  };
  const skip = e.category || e.hidden || ['unavailable', 'unknown'].includes(e.state);
  if (skip && !args.all) continue;
  entities.push(e);
}

// Group rules: what each panel type can use. Order inside a group: by area, then name.
const is = (domain, ...classes) => (e) => e.domain === domain && (!classes.length || classes.includes(e.device_class));
const RULES = {
  weather: is('weather'),
  calendar: is('calendar'),
  lights: is('light'),
  switches: (e) => ['switch', 'input_boolean', 'fan'].includes(e.domain),
  locks_covers: (e) => ['lock', 'cover'].includes(e.domain),
  scenes_scripts: (e) => ['scene', 'script', 'button', 'input_button'].includes(e.domain),
  climate: is('climate'),
  media: is('media_player'),
  energy_counters: (e) => e.domain === 'sensor' && ['energy', 'gas', 'water'].includes(e.device_class)
    && ['total_increasing', 'total'].includes(e.state_class),
  power_now: is('sensor', 'power'),
  temperature: is('sensor', 'temperature'),
  humidity: is('sensor', 'humidity'),
  air_quality: is('sensor', 'carbon_dioxide', 'pm25', 'pm10', 'volatile_organic_compounds', 'aqi'),
  battery: is('sensor', 'battery'),
  doors_windows: is('binary_sensor', 'door', 'window', 'garage_door', 'opening'),
  motion: is('binary_sensor', 'motion', 'occupancy', 'presence'),
  people: is('person'),
  appliances: (e) => e.domain === 'sensor' && /(machine_state|operation_state|job_state|program|completion_time|finish_time|remaining)/.test(e.entity_id),
  vehicles: (e) => e.domain === 'sensor' && /(battery_level|battery_percentage|state_of_charge|range)/.test(e.entity_id) && e.device_class !== 'battery',
};

const byAreaThenName = (a, b) => (a.area ?? '~').localeCompare(b.area ?? '~') || a.name.localeCompare(b.name);
const candidates = {};
for (const [group, rule] of Object.entries(RULES)) {
  candidates[group] = entities.filter(rule).sort(byAreaThenName)
    .map(({ entity_id, name, area, state, unit, device_class, platform, options }) =>
      ({ entity_id, name, area, state, unit, device_class, platform, ...(options ? { options } : {}) }));
}

// Calendars: how many events in the next 30 days. A calendar that is empty
// there makes an empty agenda on the wall — better known before proposing it.
const from = new Date(), to = new Date(Date.now() + 30 * 864e5);
await Promise.all(candidates.calendar.map(async (c) => {
  try {
    const events = await restGet(haUrl, token,
      `/api/calendars/${c.entity_id}?start=${encodeURIComponent(from.toISOString())}&end=${encodeURIComponent(to.toISOString())}`);
    c.upcoming30d = events.length;
  } catch { c.upcoming30d = null; }
}));

const inventory = {
  generated: new Date().toISOString(),
  user: { name: me?.name, isAdmin: !!me?.is_admin },
  ha: { url: haUrl, version: ha.haVersion, location: config.location_name, timeZone: config.time_zone,
    language: config.language, country: config.country, units: config.unit_system },
  sunAvailable: states.some((s) => s.entity_id === 'sun.sun'),
  registryAvailable: entityReg.length > 0,
  areas: [...areas.values()].sort(),
  counts: Object.fromEntries(Object.entries(candidates).map(([k, v]) => [k, v.length])),
  candidates,
  entities,
};

const out = args.out ?? join(resolve(args.project), 'inventory.json');
writeFileSync(out, JSON.stringify(inventory, null, 2));

if (!args.quiet) {
  console.log(`Home Assistant ${inventory.ha.version} — "${inventory.ha.location}" (${inventory.ha.timeZone}, ${inventory.ha.language})`);
  console.log(`Token belongs to "${inventory.user.name}"${inventory.user.isAdmin ? ' (admin)' : ' (not admin)'}`);
  console.log(`${entities.length} usable entities of ${states.length}; ${inventory.areas.length} areas: ${inventory.areas.join(', ') || '(none)'}`);
  if (!inventory.registryAvailable) console.log('note: entity registry not readable (non-admin token) — areas and diagnostic filtering unavailable.');
  console.log('');
  for (const [group, list] of Object.entries(candidates)) {
    if (!list.length) continue;
    const sample = list.slice(0, 4).map((e) => e.entity_id + (e.upcoming30d != null ? ` (${e.upcoming30d} events/30d)` : '')).join(', ');
    console.log(`${group.padEnd(16)} ${String(list.length).padStart(4)}  ${sample}${list.length > 4 ? ', …' : ''}`);
  }
  console.log(`\nFull inventory: ${out}`);
}
