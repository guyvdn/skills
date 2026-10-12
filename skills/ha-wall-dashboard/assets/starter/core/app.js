// Boots the dashboard: theme, layout, live connection, panels.
// Everything that differs between homes lives in dashboard.config.js; this file
// should not need editing to add, move or re-point a panel.
import CONFIG from '../dashboard.config.js';
import { HA_TOKEN } from '../config.local.js';
import { connectLive } from './ha-client.js';
import { StateStore } from './state-store.js';
import { translator, timeZoneNotice } from './i18n.js';
import { mountLayout, applyTheme, applyLook } from './layout.js';

export function boot() {
  const root = document.documentElement;
  const locale = CONFIG.locale ?? navigator.language ?? 'en';
  const t = translator(locale, CONFIG.labels);
  root.lang = locale;
  applyLook(CONFIG, root);

  // Same origin for WebSocket and REST, always. A hardcoded IP breaks the day
  // the tablet opens the page via a hostname instead (cross-origin -> blocked).
  const baseUrl = location.origin;
  const wsUrl = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/websocket';

  const store = new StateStore();
  const pill = connectionPill(t);
  const client = connectLive({
    token: HA_TOKEN, wsUrl, store,
    heartbeatMs: 30000, // a wall tablet must notice a half-open socket on its own
    onStatus: (s) => {
      pill(s);
      if (s === 'connected') publishTimeZone(client, store, t);
    },
  });

  applyTheme(CONFIG.theme ?? 'tron', store, root);
  const ctx = { store, client, token: HA_TOKEN, baseUrl, locale, t, config: CONFIG };
  mountLayout(document.getElementById('dash'), CONFIG.columns ?? [], ctx);
}

// The home's time zone: config.timeZone, else HA's own. The clock shows it.
// Everything else that is day-based (calendar days, "today" energy) follows
// the TABLET's zone, so when the two differ the wall says so instead of
// quietly resetting "today" at the wrong hour.
async function publishTimeZone(client, store, t) {
  const ha = CONFIG.timeZone ?? (await client.request({ type: 'get_config' }))?.time_zone;
  if (!ha) return;
  store.set('_local.time_zone', { entity_id: '_local.time_zone', state: ha, attributes: {} });
  const tablet = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const notice = timeZoneNotice(t, tablet, ha);
  let el = document.getElementById('tz-notice');
  if (!notice) { el?.remove(); return; }
  if (!el) {
    el = Object.assign(document.createElement('div'), { id: 'tz-notice', className: 'notice is-warn' });
    document.body.append(el);
  }
  el.textContent = notice;
}

// Bottom-left pill, hidden while connected. A dashboard silently showing
// hour-old values is worse than one that says it lost the connection.
function connectionPill(t) {
  const el = document.getElementById('conn');
  return (s) => {
    if (s === 'connected') { el.hidden = true; return; }
    el.textContent = t(s);
    el.className = 'conn ' + (s === 'auth_failed' ? 'is-error' : 'is-warn');
    el.hidden = false;
  };
}
