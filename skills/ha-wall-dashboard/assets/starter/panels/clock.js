// Big clock + date. Config: { type: 'clock', seconds?: false, hour12?: <locale default> }
//
// Shows HA's time zone (or config.timeZone), not the tablet's: a tablet left
// on UTC would otherwise show the wrong time on the wall. app.js publishes
// the zone as the synthetic '_local.time_zone' once connected.
export const card = true;

export function render(el, cfg, { locale, store }) {
  el.classList.add('clock');
  const time = document.createElement('div'); time.className = 'clock-time';
  const date = document.createElement('div'); date.className = 'clock-date';
  el.append(time, date);

  let timeFmt, dateFmt;
  function formatters(timeZone) {
    const tz = timeZone ? { timeZone } : {};
    timeFmt = new Intl.DateTimeFormat(locale, {
      ...tz, hour: '2-digit', minute: '2-digit', ...(cfg.seconds ? { second: '2-digit' } : {}),
      ...(cfg.hour12 != null ? { hour12: cfg.hour12 } : {}),
    });
    dateFmt = new Intl.DateTimeFormat(locale, { ...tz, weekday: 'long', day: 'numeric', month: 'long' });
  }

  function paint() {
    const now = new Date();
    time.textContent = timeFmt.format(now);
    // First letter only: CSS capitalize would also capitalize month names,
    // which is wrong in most languages other than English.
    const d = dateFmt.format(now);
    date.textContent = d.charAt(0).toUpperCase() + d.slice(1);
  }

  formatters(null);
  store.subscribe(['_local.time_zone'], (s) => {
    try { formatters(s?.state ?? null); } catch { formatters(null); } // unknown zone name: tablet's own
    paint();
  });
  setInterval(paint, cfg.seconds ? 1000 : 10 * 1000);
}
