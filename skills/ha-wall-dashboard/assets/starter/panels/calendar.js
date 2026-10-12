// Agenda for the next N days, merged from several HA calendars, one colour each.
// Config: { type: 'calendar', days?: 7, calendars: [{ entity, color?, skipMultiDay? }] }
//
// Calendars are fetched over REST every 5 minutes (events are not entity
// state). allSettled: one broken calendar must not blank the whole panel.
import { getCalendarEvents } from '../core/ha-client.js';
import { normalizeEvents, dedupeEvents, groupByDay, isMultiDay } from './logic.js';

export const card = true;

export function render(el, cfg, { token, baseUrl, locale, t }) {
  el.classList.add('calendar');
  const days = cfg.days ?? 7;
  const rel = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  const weekday = new Intl.DateTimeFormat(locale, { weekday: 'long' });
  const dayMonth = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' });
  const hm = new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit' });
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

  function message(text, cls) {
    const m = document.createElement('div');
    m.className = cls;
    m.textContent = text;
    el.replaceChildren(m);
  }

  let loadedOnce = false;
  async function load() {
    const now = new Date();
    const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days);
    const results = await Promise.allSettled(cfg.calendars.map(async (c) => {
      const raw = await getCalendarEvents({
        baseUrl, token, entityId: c.entity, start: now.toISOString(), end: end.toISOString(),
      });
      const events = normalizeEvents(raw, c.color ?? null);
      return c.skipMultiDay ? events.filter((e) => !isMultiDay(e)) : events;
    }));
    results.filter((r) => r.status === 'rejected').forEach((r) => console.error('Calendar failed:', r.reason));
    const ok = results.filter((r) => r.status === 'fulfilled');
    // A failed refresh keeps the last good agenda (a few minutes stale beats an
    // error on the wall); the error only shows if nothing has loaded yet.
    if (!ok.length) { if (!loadedOnce) message(t('calendarError'), 'cal-error'); return; }
    loadedOnce = true;

    const groups = groupByDay(dedupeEvents(ok.flatMap((r) => r.value)), now, days);
    if (!groups.length) { message(t('noEvents'), 'cal-empty'); return; }

    el.replaceChildren(...groups.map((g) => {
      const day = document.createElement('section'); day.className = 'cal-day';
      const head = document.createElement('header'); head.className = 'cal-day-head';
      const name = document.createElement('span'); name.className = 'cal-weekday';
      name.textContent = cap(g.offset < 2 ? rel.format(g.offset, 'day') : weekday.format(g.date));
      const date = document.createElement('span'); date.className = 'cal-date';
      date.textContent = dayMonth.format(g.date);
      head.append(name, date);
      day.append(head);
      for (const e of g.events) {
        const row = document.createElement('div'); row.className = 'cal-event';
        if (e.color) row.style.setProperty('--evt-color', e.color);
        const when = document.createElement('span'); when.className = 'cal-time';
        when.textContent = e.allDay ? t('allDay') : `${hm.format(e.start)}–${hm.format(e.end)}`;
        const title = document.createElement('span'); title.className = 'cal-title';
        title.textContent = e.title;
        row.append(when, title);
        day.append(row);
      }
      return day;
    }));
  }

  load();
  setInterval(load, 5 * 60 * 1000);
}
