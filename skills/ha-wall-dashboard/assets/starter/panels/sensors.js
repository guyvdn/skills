// Read-only value tiles: temperatures, power, CO₂, battery, anything numeric.
// Also serves type 'energy', where items default to today: true.
// Config: { type: 'sensors' | 'energy', columns?: 3, items: [{
//   entity, name?, icon?, attribute?, decimals?, unit?,
//   today?: false,      // show current − value at local midnight (lifetime counters)
//   warnAbove?, warnBelow?, dangerAbove?, dangerBelow?, okAbove?,
// }] }
import { createTile, createTileGrid } from '../core/tile.js';
import { iconSvg } from '../core/icons.js';
import { setWithUnit, displayUnit, fmtNumber, num } from '../core/format.js';
import { fetchMidnightValue, todayDelta } from '../core/history.js';
import { thresholdClass, isUnavailable, defaultIcon } from './logic.js';

export const card = false;

export function render(el, cfg, ctx) {
  const { store, locale } = ctx;
  const grid = createTileGrid(cfg.columns ?? 3, cfg.items.length);
  el.append(grid);

  for (const item of cfg.items) {
    const today = item.today ?? cfg.type === 'energy';
    const tile = createTile();
    tile.el.classList.add('tile-sensor');
    grid.append(tile.el);

    let baseline = today ? null : undefined;

    function paint() {
      const s = store.get(item.entity);
      tile.setName(item.name ?? s?.attributes?.friendly_name ?? item.entity);
      tile.center.innerHTML = iconSvg(item.icon ?? defaultIcon(item.entity, s)); // trusted constant SVG
      const raw = item.attribute ? s?.attributes?.[item.attribute] : s?.state;
      let v = today ? todayDelta(raw, baseline, item.decimals ?? 2) : num(raw);
      const decimals = item.decimals ?? (today ? 2 : 1);
      const { unit, sup } = displayUnit(item.unit ?? s?.attributes?.unit_of_measurement ?? '');
      setWithUnit(tile.value, v == null ? null : fmtNumber(v, decimals, locale), unit, sup);
      tile.fitValue();
      const cls = thresholdClass(v, item);
      tile.el.classList.remove('is-warn', 'is-danger', 'is-ok');
      if (cls) tile.el.classList.add(cls);
      tile.el.classList.toggle('is-unavailable', isUnavailable(s));
    }
    store.subscribe([item.entity], paint);

    if (today) armMidnightBaseline(item.entity, ctx, (b) => { baseline = b; paint(); });
  }
}

// Fetch today's baseline now, then again just after every local midnight —
// the tablet runs for weeks without a reload. A failed fetch (tablet booted
// before the wifi, HA restarting) is retried every 5 minutes; otherwise the
// tile would show a dash until the next midnight.
const RETRY_MS = 5 * 60 * 1000;
function armMidnightBaseline(entityId, { token, baseUrl }, onBaseline) {
  let retry = null;
  const load = async () => {
    clearTimeout(retry);
    const b = await fetchMidnightValue({ baseUrl, token, entityId });
    onBaseline(b);
    if (b == null) retry = setTimeout(load, RETRY_MS);
  };
  load();
  const schedule = () => {
    const now = new Date();
    const next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 1);
    setTimeout(() => { load(); schedule(); }, next - now);
  };
  schedule();
}
