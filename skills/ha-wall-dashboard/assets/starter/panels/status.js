// "What needs attention" chips: open doors and windows, motion, who is home.
// By default only active items show, and an all-clear line when there are none.
// Config: { type: 'status', showAll?: false, emptyText?, items: [{ entity, name?, icon?, activeStates? }] }
// activeStates: states that count as active, replacing on/open/home/…, e.g. ['run', 'pause']
import { iconSvg } from '../core/icons.js';
import { isActive, defaultIcon } from './logic.js';

export const card = true;

export function render(el, cfg, { store, t }) {
  el.classList.add('status');
  const list = document.createElement('div'); list.className = 'status-list';
  el.append(list);
  const ids = cfg.items.map((i) => i.entity);

  function paint() {
    const chips = [];
    for (const item of cfg.items) {
      const s = store.get(item.entity);
      const on = isActive(s, item.activeStates);
      if (!on && !cfg.showAll) continue;
      const chip = document.createElement('div');
      // An open door wants attention; a person being home is simply good news.
      const tone = item.entity.startsWith('person.') ? ' is-home' : ' is-on';
      chip.className = 'status-chip' + (on ? tone : '');
      const ic = document.createElement('span'); ic.className = 'status-icon';
      ic.innerHTML = iconSvg(item.icon ?? defaultIcon(item.entity, s)); // trusted constant SVG
      const label = document.createElement('span');
      label.textContent = item.name ?? s?.attributes?.friendly_name ?? item.entity;
      chip.append(ic, label);
      chips.push(chip);
    }
    if (!chips.length) {
      const ok = document.createElement('div'); ok.className = 'status-clear';
      ok.innerHTML = iconSvg('check-circle'); // trusted constant SVG
      ok.append(cfg.emptyText ?? t('allClear'));
      chips.push(ok);
    }
    list.replaceChildren(...chips);
  }
  store.subscribe(ids, paint);
}
