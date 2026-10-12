// Big clock + date. Config: { type: 'clock', seconds?: false, hour12?: <locale default> }
export const card = true;

export function render(el, cfg, { locale }) {
  el.classList.add('clock');
  const time = document.createElement('div'); time.className = 'clock-time';
  const date = document.createElement('div'); date.className = 'clock-date';
  el.append(time, date);

  const timeFmt = new Intl.DateTimeFormat(locale, {
    hour: '2-digit', minute: '2-digit', ...(cfg.seconds ? { second: '2-digit' } : {}),
    ...(cfg.hour12 != null ? { hour12: cfg.hour12 } : {}),
  });
  const dateFmt = new Intl.DateTimeFormat(locale, { weekday: 'long', day: 'numeric', month: 'long' });

  function paint() {
    const now = new Date();
    time.textContent = timeFmt.format(now);
    // First letter only: CSS capitalize would also capitalize month names,
    // which is wrong in most languages other than English.
    const d = dateFmt.format(now);
    date.textContent = d.charAt(0).toUpperCase() + d.slice(1);
  }
  paint();
  setInterval(paint, cfg.seconds ? 1000 : 10 * 1000);
}
