// Thermostat / air-conditioning tiles. Tap toggles on/off; the − and + in the
// top corners nudge the setpoint by the entity's own step.
// Config: { type: 'climate', columns?: 2, items: [{ entity, name? }] }
//
// Setpoint taps are debounced: three quick + taps send ONE set_temperature
// call for the final value. Cloud-polled units (Daikin, Mitsubishi, ...) rate
// limit, and a call per tap gets the integration throttled.
import { createTile, createTileGrid } from '../core/tile.js';
import { iconSvg } from '../core/icons.js';
import { fmtNumber } from '../core/format.js';
import { climateView, climateTapAction, clampTarget, isUnavailable } from './logic.js';

export const card = false;
const DEBOUNCE_MS = 1200;

export function render(el, cfg, { store, client, locale }) {
  const grid = createTileGrid(cfg.columns ?? 2, cfg.items.length);
  el.append(grid);

  for (const item of cfg.items) {
    const tile = createTile({ interactive: true });
    tile.el.classList.add('tile-climate');
    grid.append(tile.el);

    const minus = stepButton('minus');
    const plus = stepButton('plus');
    tile.topLeft.append(minus);
    tile.topRight.append(plus);

    let pendingTarget = null;
    let timer = null;

    function paint() {
      const s = store.get(item.entity);
      const v = climateView(s);
      tile.setName(item.name ?? s?.attributes?.friendly_name ?? item.entity);
      tile.center.innerHTML = iconSvg(v.icon); // trusted constant SVG
      tile.el.classList.toggle('is-on', v.on);
      tile.el.classList.toggle('is-warm', v.on && v.warm);
      tile.el.classList.toggle('is-unavailable', isUnavailable(s));
      const target = pendingTarget ?? v.target;
      const digits = v.step < 1 ? 1 : 0;
      const setpoint = v.range
        ? ` / ${fmtNumber(v.range[0], digits, locale)}–${fmtNumber(v.range[1], digits, locale)}°`
        : (target == null ? '' : ` / ${fmtNumber(target, digits, locale)}°`);
      // No single setpoint (range mode, or a fan-only unit): hide the ± buttons.
      const adjustable = v.target != null;
      minus.style.visibility = plus.style.visibility = adjustable ? '' : 'hidden';
      tile.value.replaceChildren(
        v.current == null ? '—' : `${fmtNumber(v.current, 1, locale)}°`,
        Object.assign(document.createElement('span'), {
          className: 'climate-target' + (pendingTarget != null ? ' is-pending' : ''),
          textContent: setpoint,
        }),
      );
      tile.fitValue();
    }
    store.subscribe([item.entity], paint);

    function nudge(direction, e) {
      e.stopPropagation(); // don't also toggle the tile
      const v = climateView(store.get(item.entity));
      const base = pendingTarget ?? v.target;
      if (base == null) return;
      pendingTarget = clampTarget(base, direction * v.step, v);
      paint();
      clearTimeout(timer);
      timer = setTimeout(() => {
        client.callService('climate', 'set_temperature', { entity_id: item.entity }, { temperature: pendingTarget });
        pendingTarget = null; // the state_changed echo repaints with HA's value
      }, DEBOUNCE_MS);
    }
    minus.addEventListener('click', (e) => nudge(-1, e));
    plus.addEventListener('click', (e) => nudge(+1, e));

    tile.el.addEventListener('click', () => {
      const action = climateTapAction(store.get(item.entity));
      if (action) client.callService('climate', action.service, { entity_id: item.entity }, action.data);
    });
  }
}

function stepButton(icon) {
  const b = document.createElement('span');
  b.className = 'climate-step';
  b.setAttribute('role', 'button');
  b.innerHTML = iconSvg(icon); // trusted constant SVG
  return b;
}
