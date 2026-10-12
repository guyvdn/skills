// Missing values render as a bare dash — never "— kWh" or "—%".
export const MISSING = '—';

// Number from a state string, or null for unknown/unavailable/garbage.
export function num(raw) {
  if (raw == null || raw === '') return null;
  const v = Number(raw);
  return Number.isFinite(v) ? v : null;
}

export function fmtNumber(value, decimals, locale) {
  if (value == null) return MISSING;
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: decimals, maximumFractionDigits: decimals,
  }).format(value);
}

// Set el's children to [value, <span class="unit">unit</span>]. The unit is
// smaller than the number; sup=true raises it (for °).
export function setWithUnit(el, value, unit, sup = false) {
  if (value === MISSING || value == null) { el.replaceChildren(MISSING); return; }
  if (!unit) { el.replaceChildren(String(value)); return; }
  const u = document.createElement('span');
  u.className = sup ? 'unit unit-sup' : 'unit';
  u.textContent = unit;
  el.replaceChildren(String(value), u);
}

// Degree units sit raised and lose the letter (21.5°); the rest stay on the baseline.
export function displayUnit(unit) {
  if (unit === '°C' || unit === '°F' || unit === '°') return { unit: '°', sup: true };
  return { unit: unit ?? '', sup: false };
}
