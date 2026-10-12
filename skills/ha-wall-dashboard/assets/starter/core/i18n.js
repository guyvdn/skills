// The few fixed strings the dashboard draws itself. Everything else is either
// a name from the config or formatted by Intl for config.locale.
// Add a language by copying the `en` block.
const STRINGS = {
  en: {
    connecting: 'Connecting…', reconnecting: 'Connection lost', auth_failed: 'Login failed — check the token',
    allDay: 'All day', noEvents: 'Nothing planned', calendarError: 'Calendar unavailable',
    allClear: 'All closed', nothingPlaying: 'Nothing playing', humidity: 'Humidity', wind: 'Wind',
    panelError: 'Panel failed — see console',
    timeZoneMismatch: 'Tablet time zone {tablet} ≠ Home Assistant {ha}',
  },
  nl: {
    connecting: 'Verbinden…', reconnecting: 'Verbinding verbroken', auth_failed: 'Aanmelden mislukt — controleer het token',
    allDay: 'Hele dag', noEvents: 'Niets gepland', calendarError: 'Agenda niet beschikbaar',
    allClear: 'Alles dicht', nothingPlaying: 'Er speelt niets', humidity: 'Vochtigheid', wind: 'Wind',
    panelError: 'Paneel mislukt — zie console',
    timeZoneMismatch: 'Tijdzone tablet {tablet} ≠ Home Assistant {ha}',
  },
  fr: {
    connecting: 'Connexion…', reconnecting: 'Connexion perdue', auth_failed: 'Échec de connexion — vérifiez le jeton',
    allDay: 'Toute la journée', noEvents: 'Rien de prévu', calendarError: 'Agenda indisponible',
    allClear: 'Tout est fermé', nothingPlaying: 'Aucune lecture', humidity: 'Humidité', wind: 'Vent',
    panelError: 'Échec du panneau — voir la console',
    timeZoneMismatch: 'Fuseau de la tablette {tablet} ≠ Home Assistant {ha}',
  },
  de: {
    connecting: 'Verbinde…', reconnecting: 'Verbindung verloren', auth_failed: 'Anmeldung fehlgeschlagen — Token prüfen',
    allDay: 'Ganztägig', noEvents: 'Nichts geplant', calendarError: 'Kalender nicht verfügbar',
    allClear: 'Alles geschlossen', nothingPlaying: 'Keine Wiedergabe', humidity: 'Feuchte', wind: 'Wind',
    panelError: 'Panel-Fehler — siehe Konsole',
    timeZoneMismatch: 'Zeitzone Tablet {tablet} ≠ Home Assistant {ha}',
  },
};

// translator('nl-BE', { allClear: 'Alles op slot' }) — overrides win, then the
// language, then English.
export function translator(locale = 'en', overrides = {}) {
  const lang = String(locale).slice(0, 2).toLowerCase();
  const table = { ...STRINGS.en, ...(STRINGS[lang] ?? {}), ...overrides };
  return (key) => table[key] ?? key;
}

// The warning shown when the tablet's own time zone isn't the home's, or null.
// Compared by the current UTC offset rather than by name, so equivalent names
// (Europe/Brussels vs Europe/Amsterdam, both CET) don't raise a false alarm.
export function timeZoneNotice(t, tabletTz, haTz, now = new Date()) {
  if (!tabletTz || !haTz || tabletTz === haTz) return null;
  const offset = (tz) => {
    try {
      const p = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'longOffset' }).formatToParts(now);
      return p.find((x) => x.type === 'timeZoneName')?.value;
    } catch { return null; } // a zone name this browser doesn't know
  };
  const a = offset(tabletTz), b = offset(haTz);
  if (a && b && a === b) return null;
  return t('timeZoneMismatch').replace('{tablet}', tabletTz).replace('{ha}', haTz);
}
