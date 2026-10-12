// Pure view logic for every panel: no DOM, no network, so `node --test`
// covers it. Panels call these and only do the painting themselves.

const ON_STATES = new Set(['on', 'open', 'opening', 'unlocked', 'home', 'playing', 'detected', 'heat', 'cool']);
const DEAD_STATES = new Set(['unavailable', 'unknown']);

export const isUnavailable = (stateObj) => !stateObj || DEAD_STATES.has(stateObj.state);

// "Is this thing active?" across domains: a light that is on, a door that is
// open, a person who is home. Climate and media have their own views below.
// `activeStates` replaces the defaults for entities with their own vocabulary,
// e.g. a washer's machine_state: ['run', 'pause'].
export function isActive(stateObj, activeStates) {
  if (!stateObj) return false;
  return activeStates ? activeStates.includes(stateObj.state) : ON_STATES.has(stateObj.state);
}

// What a tap on a toggle tile should call. Scenes, scripts and buttons are
// momentary — they run, they don't flip — so they get their own services.
export function tapAction(entityId) {
  const domain = entityId.split('.')[0];
  switch (domain) {
    case 'scene': return { domain: 'scene', service: 'turn_on' };
    case 'script': return { domain: 'script', service: 'turn_on' };
    case 'button': case 'input_button': return { domain, service: 'press' };
    case 'lock': return null; // decided per state: see lockAction
    case 'cover': return { domain: 'cover', service: 'toggle' };
    default: return { domain: 'homeassistant', service: 'toggle' };
  }
}

export const isMomentary = (entityId) => /^(scene|script|button|input_button)\./.test(entityId);

export function lockAction(stateObj) {
  return stateObj?.state === 'locked'
    ? { domain: 'lock', service: 'unlock' }
    : { domain: 'lock', service: 'lock' };
}

// Default icon for an entity when the config gives none.
export function defaultIcon(entityId, stateObj) {
  const domain = entityId.split('.')[0];
  const dc = stateObj?.attributes?.device_class;
  const on = isActive(stateObj);
  if (domain === 'light') return on ? 'lightbulb' : 'lightbulb-outline';
  if (domain === 'switch') return dc === 'outlet' ? (on ? 'power-plug' : 'power-plug-off') : 'toggle-switch';
  if (domain === 'fan') return 'fan';
  if (domain === 'scene') return 'palette';
  if (domain === 'script') return 'script-text-play-outline';
  if (domain === 'button' || domain === 'input_button') return 'gesture-tap-button';
  if (domain === 'lock') return on ? 'lock-open-variant' : 'lock';
  if (domain === 'cover') return on ? 'blinds-open' : 'blinds';
  if (domain === 'person') return on ? 'account' : 'account-off';
  if (domain === 'media_player') return 'speaker';
  if (domain === 'climate') return 'thermostat';
  if (dc === 'door' || dc === 'garage_door') return on ? 'door-open' : 'door';
  if (dc === 'window') return on ? 'window-open' : 'window-closed';
  if (dc === 'motion' || dc === 'occupancy' || dc === 'presence') return 'motion-sensor';
  if (dc === 'temperature') return 'thermometer';
  if (dc === 'humidity') return 'water-percent';
  if (dc === 'battery') return 'battery-50';
  if (dc === 'power') return 'flash';
  if (dc === 'energy') return 'meter-electric';
  if (dc === 'gas') return 'meter-gas';
  if (dc === 'water') return 'water';
  if (dc === 'carbon_dioxide') return 'molecule-co2';
  if (dc === 'pm25' || dc === 'pm10') return 'air-filter';
  return 'gauge';
}

// HA weather condition -> MDI icon name.
const WEATHER_ICONS = {
  'clear-night': 'weather-night', cloudy: 'weather-cloudy', exceptional: 'alert-circle',
  fog: 'weather-fog', hail: 'weather-hail', lightning: 'weather-lightning',
  'lightning-rainy': 'weather-lightning-rainy', partlycloudy: 'weather-partly-cloudy',
  pouring: 'weather-pouring', rainy: 'weather-rainy', snowy: 'weather-snowy',
  'snowy-rainy': 'weather-snowy-rainy', sunny: 'weather-sunny', windy: 'weather-windy',
  'windy-variant': 'weather-windy-variant',
};
export const weatherIcon = (condition) => WEATHER_ICONS[condition] ?? 'weather-cloudy';

// Conditions that earn a colour of their own; the rest stay in the muted text colour.
const WEATHER_TONE = {
  sunny: 'sun', partlycloudy: 'sun', lightning: 'sun', 'lightning-rainy': 'sun',
  rainy: 'rain', pouring: 'rain', 'snowy-rainy': 'rain', snowy: 'cold', hail: 'cold', 'clear-night': 'night',
};
export const weatherTone = (condition) => WEATHER_TONE[condition] ?? '';

// Climate entity -> what the tile shows.
const HVAC_ICONS = {
  off: 'power', heat: 'fire', cool: 'snowflake', heat_cool: 'thermostat', auto: 'thermostat',
  dry: 'water-percent', fan_only: 'fan',
};
export function climateView(stateObj) {
  const a = stateObj?.attributes ?? {};
  const mode = stateObj?.state ?? 'unavailable';
  // Range mode (heat_cool on many thermostats): two setpoints, no single
  // `temperature`. set_temperature then needs target_temp_low/high, so the
  // ± buttons are disabled there rather than sending a call HA rejects.
  const range = a.temperature == null && a.target_temp_low != null && a.target_temp_high != null;
  return {
    on: !!stateObj && mode !== 'off' && !DEAD_STATES.has(mode),
    mode,
    warm: mode === 'heat',
    icon: HVAC_ICONS[mode] ?? 'thermostat',
    current: a.current_temperature ?? null,
    target: a.temperature ?? null,
    range: range ? [a.target_temp_low, a.target_temp_high] : null,
    step: a.target_temp_step ?? (a.temperature_unit === '°F' ? 1 : 0.5),
    min: a.min_temp ?? 7,
    max: a.max_temp ?? 35,
  };
}

// What a tap on a climate tile calls. climate.turn_on / turn_off only work on
// entities that declare them (ClimateEntityFeature TURN_ON = 256,
// TURN_OFF = 128); recent HA rejects them otherwise. Fall back to
// set_hvac_mode: 'off', or the first mode that isn't off (heat, cool, …).
export function climateTapAction(stateObj) {
  const a = stateObj?.attributes ?? {};
  const features = a.supported_features ?? 0;
  const on = climateView(stateObj).on;
  if (on) {
    return features & 128
      ? { service: 'turn_off' }
      : { service: 'set_hvac_mode', data: { hvac_mode: 'off' } };
  }
  if (features & 256) return { service: 'turn_on' };
  const mode = (a.hvac_modes ?? []).find((m) => m !== 'off');
  return mode ? { service: 'set_hvac_mode', data: { hvac_mode: mode } } : null;
}

export function clampTarget(target, delta, view) {
  const next = Math.round((target + delta) / view.step) * view.step;
  return Math.min(view.max, Math.max(view.min, Number(next.toFixed(2))));
}

// Threshold colouring for a sensor value: '' | 'is-warn' | 'is-danger' | 'is-ok'.
export function thresholdClass(value, item) {
  if (value == null) return '';
  if (item.dangerAbove != null && value > item.dangerAbove) return 'is-danger';
  if (item.dangerBelow != null && value < item.dangerBelow) return 'is-danger';
  if (item.warnAbove != null && value > item.warnAbove) return 'is-warn';
  if (item.warnBelow != null && value < item.warnBelow) return 'is-warn';
  if (item.okAbove != null && value >= item.okAbove) return 'is-ok';
  return '';
}

// Media player -> what the media card shows.
export function mediaView(stateObj) {
  const a = stateObj?.attributes ?? {};
  const state = stateObj?.state ?? 'unavailable';
  return {
    playing: state === 'playing',
    idle: !stateObj || ['off', 'idle', 'standby', 'unavailable', 'unknown'].includes(state),
    title: a.media_title ?? '',
    artist: a.media_artist ?? a.media_album_name ?? a.app_name ?? '',
    picture: a.entity_picture ?? null,
    volume: a.volume_level ?? null,
  };
}

// ---- Calendar ----

const pad = (n) => String(n).padStart(2, '0');
export const dayKey = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

// HA calendar event -> { title, start: Date, end: Date, allDay, color }.
// All-day dates are local dates; parse them as local midnight, not UTC.
export function normalizeEvents(raw, color = null) {
  return (raw ?? []).map((e) => {
    const allDay = !!e.start?.date && !e.start?.dateTime;
    const start = allDay ? new Date(`${e.start.date}T00:00:00`) : new Date(e.start.dateTime);
    const end = allDay ? new Date(`${e.end.date}T00:00:00`) : new Date(e.end.dateTime);
    return { title: e.summary ?? '', start, end, allDay, color };
  });
}

// Same title + same start from two calendars (a shared family event) shows once.
export function dedupeEvents(events) {
  const seen = new Set();
  return events.filter((e) => {
    const k = `${e.title}|${e.start.getTime()}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

export function compareEvents(a, b) {
  if (a.allDay !== b.allDay) return a.allDay ? -1 : 1;
  return (a.start - b.start) || (a.end - b.end);
}

// Events grouped per local day for `days` days from `now`. A multi-day event
// appears on every day it covers; an event already finished today is dropped.
export function groupByDay(events, now, days) {
  const out = [];
  for (let i = 0; i < days; i++) {
    const dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i);
    const dayEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i + 1);
    const list = events
      .filter((e) => e.start < dayEnd && e.end > dayStart && !(i === 0 && e.end <= now))
      .sort(compareEvents);
    if (list.length) out.push({ date: dayStart, key: dayKey(dayStart), offset: i, events: list });
  }
  return out;
}

// By calendar day, not by duration: a one-day event on a DST change day lasts
// 23 or 25 hours. `end` is exclusive, so the last day it covers is end − 1 ms.
export const isMultiDay = (e) => dayKey(new Date(e.end.getTime() - 1)) !== dayKey(e.start);
