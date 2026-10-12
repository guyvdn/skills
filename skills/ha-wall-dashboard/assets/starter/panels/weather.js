// Current weather + a daily forecast strip.
// Config: { type: 'weather', entity: 'weather.home', days?: 5, forecast?: 'daily' | 'hourly' | false }
//
// The forecast is not in the entity's attributes any more (removed in HA
// 2024.3); it comes from the weather.get_forecasts service, which answers with
// data — so it goes through callServiceForResponse, refreshed every 30 min.
import { iconSvg } from '../core/icons.js';
import { setWithUnit, displayUnit, fmtNumber, num } from '../core/format.js';
import { weatherIcon, weatherTone } from './logic.js';

export const card = true;

export function render(el, cfg, { store, client, locale, t }) {
  el.classList.add('weather');
  const days = cfg.days ?? 5;
  const forecastType = cfg.forecast ?? 'daily';

  const now = document.createElement('div'); now.className = 'wx-now';
  const icon = document.createElement('div'); icon.className = 'wx-icon';
  const temp = document.createElement('div'); temp.className = 'wx-temp';
  const meta = document.createElement('div'); meta.className = 'wx-meta';
  now.append(icon, temp, meta);
  const strip = document.createElement('div'); strip.className = 'wx-forecast';
  el.append(now, strip);

  const dayFmt = new Intl.DateTimeFormat(locale, { weekday: 'short' });
  const hourFmt = new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit' });

  store.subscribe([cfg.entity], (s) => {
    const a = s?.attributes ?? {};
    icon.innerHTML = iconSvg(weatherIcon(s?.state)); // trusted constant SVG
    icon.dataset.tone = weatherTone(s?.state);
    const { unit, sup } = displayUnit(a.temperature_unit ?? '°');
    setWithUnit(temp, fmtNumber(num(a.temperature), 1, locale), unit, sup);
    const bits = [];
    if (a.humidity != null) bits.push(`${t('humidity')} ${Math.round(a.humidity)}%`);
    if (a.wind_speed != null) bits.push(`${t('wind')} ${Math.round(a.wind_speed)} ${a.wind_speed_unit ?? ''}`.trim());
    meta.textContent = bits.join('  ·  ');
  });

  if (!forecastType) return;

  let loaded = false;
  async function loadForecast() {
    const res = await client.callServiceForResponse('weather', 'get_forecasts',
      { entity_id: cfg.entity }, { type: forecastType });
    const list = res?.[cfg.entity]?.forecast;
    if (!Array.isArray(list)) return false;
    paintForecast(list.slice(0, days));
    return true;
  }

  function paintForecast(list) {
    const unitInfo = displayUnit(store.get(cfg.entity)?.attributes?.temperature_unit ?? '°');
    strip.replaceChildren(...list.map((f) => {
      const cell = document.createElement('div'); cell.className = 'wx-day';
      const label = document.createElement('div'); label.className = 'wx-day-label';
      const when = new Date(f.datetime);
      label.textContent = forecastType === 'hourly' ? hourFmt.format(when) : dayFmt.format(when);
      const ic = document.createElement('div'); ic.className = 'wx-day-icon';
      ic.innerHTML = iconSvg(weatherIcon(f.condition)); // trusted constant SVG
      ic.dataset.tone = weatherTone(f.condition);
      const hi = document.createElement('div'); hi.className = 'wx-day-hi';
      setWithUnit(hi, f.temperature != null ? Math.round(f.temperature) : null, unitInfo.unit, unitInfo.sup);
      const lo = document.createElement('div'); lo.className = 'wx-day-lo';
      if (f.templow != null) setWithUnit(lo, Math.round(f.templow), unitInfo.unit, unitInfo.sup);
      const rain = document.createElement('div'); rain.className = 'wx-day-rain';
      if (f.precipitation_probability) rain.textContent = `${f.precipitation_probability}%`;
      cell.append(label, ic, hi, lo, rain);
      return cell;
    }));
  }

  // The first state callback with data means the socket is up and authenticated.
  // Until a forecast has loaded, retry each minute (HA restarting, socket down).
  store.subscribe([cfg.entity], async (s) => {
    if (!s || loaded) return;
    loaded = true;
    if (!(await loadForecast())) loaded = false;
  });
  setInterval(async () => { if (!(await loadForecast())) loaded = false; }, 30 * 60 * 1000);
  setInterval(async () => { if (!loaded) loaded = await loadForecast(); }, 60 * 1000);
}
