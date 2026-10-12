// Turns the `columns` part of the config into DOM, and applies the theme.
// Shared by the real dashboard (app.js) and the theme preview (themes.html).
import { PANELS } from '../panels/registry.js';

export function mountLayout(dash, columns, ctx) {
  dash.replaceChildren();
  dash.style.gridTemplateColumns = columns.map((c) => `minmax(0, ${c.width ?? 1}fr)`).join(' ');
  for (const col of columns) {
    const colEl = document.createElement('div');
    colEl.className = 'dash-col';
    colEl.style.gridTemplateRows = col.panels.map((p) => `minmax(0, ${p.size ?? 1}fr)`).join(' ');
    dash.append(colEl);
    for (const p of col.panels) colEl.append(mountPanel(p, ctx));
  }
}

// One failing panel (typo in an entity id, an integration returning something
// odd) must not take the rest of the wall down with it.
function mountPanel(cfg, ctx) {
  const el = document.createElement('section');
  const mod = PANELS[cfg.type];
  el.className = `panel panel-${cfg.type}` + (mod?.card ? ' card' : '');
  if (cfg.title) {
    const h = document.createElement('h2');
    h.className = 'panel-title';
    h.textContent = cfg.title;
    el.append(h);
  }
  const body = document.createElement('div');
  body.className = 'panel-body';
  el.append(body);
  try {
    if (!mod) throw new Error(`Unknown panel type "${cfg.type}"`);
    mod.render(body, cfg, ctx);
  } catch (err) {
    console.error(`Panel "${cfg.type}" failed:`, err);
    el.classList.add('card', 'is-broken');
    body.textContent = `${cfg.type}: ${ctx.t('panelError')}`;
  }
  return el;
}

// theme: 'tron' | { day: 'daylight', night: 'tron' } (follows sun.sun).
export function applyTheme(theme, store, root = document.documentElement) {
  if (typeof theme === 'string') { root.dataset.theme = theme; return; }
  root.dataset.theme = theme.night;
  store.subscribe(['sun.sun'], (s) => {
    if (!s) return;
    root.dataset.theme = s.state === 'above_horizon' ? theme.day : theme.night;
  });
}

export function applyLook(config, root = document.documentElement) {
  if (config.scale) root.style.setProperty('--scale', config.scale);
  for (const [k, v] of Object.entries(config.themeOverrides ?? {})) root.style.setProperty(k, v);
}
