// Tap-to-toggle tiles: lights, switches, plugs, fans, locks, covers, plus
// momentary scenes / scripts / buttons.
// Config: { type: 'toggles', columns?: 3, items: [{
//   entity, name?, icon?,
//   value?:  { entity, attribute?, decimals?, unit? },   // e.g. room temperature under the name
//   corner?: { entity, attribute?, unit? },              // top-right, e.g. a remote's battery %
// }] }
import { createTile, createTileGrid } from '../core/tile.js';
import { iconSvg } from '../core/icons.js';
import { setWithUnit, displayUnit, fmtNumber, num } from '../core/format.js';
import { isActive, isUnavailable, tapAction, lockAction, isMomentary, defaultIcon } from './logic.js';

export const card = false;

export function render(el, cfg, { store, client, locale }) {
  const grid = createTileGrid(cfg.columns ?? 3, cfg.items.length);
  el.append(grid);

  for (const item of cfg.items) {
    const tile = createTile({ interactive: true });
    tile.el.classList.add('tile-toggle');
    grid.append(tile.el);

    store.subscribe([item.entity], (s) => {
      tile.setName(item.name ?? s?.attributes?.friendly_name ?? item.entity);
      tile.center.innerHTML = iconSvg(item.icon ?? defaultIcon(item.entity, s)); // trusted constant SVG
      tile.el.classList.toggle('is-on', !isMomentary(item.entity) && isActive(s));
      tile.el.classList.toggle('is-unavailable', isUnavailable(s) && !isMomentary(item.entity));
    });

    if (item.value) bindValue(tile.value, item.value, store, locale, tile.fitValue);
    if (item.corner) bindValue(tile.topRight, item.corner, store, locale);

    tile.el.addEventListener('click', () => {
      const s = store.get(item.entity);
      const action = item.entity.startsWith('lock.') ? lockAction(s) : tapAction(item.entity);
      const sent = client.callService(action.domain, action.service, { entity_id: item.entity });
      // A momentary action has no state to flip, so acknowledge the tap visibly.
      flash(tile.el, sent ? 'is-pulse' : 'is-failed');
    });
  }
}

function bindValue(target, spec, store, locale, after = () => {}) {
  store.subscribe([spec.entity], (s) => {
    const raw = spec.attribute ? s?.attributes?.[spec.attribute] : s?.state;
    const v = num(raw);
    const { unit, sup } = displayUnit(spec.unit ?? s?.attributes?.unit_of_measurement ?? '');
    setWithUnit(target, v == null ? null : fmtNumber(v, spec.decimals ?? 0, locale), unit, sup);
    after();
  });
}

function flash(el, cls) {
  el.classList.add(cls);
  setTimeout(() => el.classList.remove(cls), 700);
}
