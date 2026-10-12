// Midnight-baseline helpers for "today" values from lifetime counters
// (energy kWh, gas m³, water L): today = current − value at local midnight.

// Value of an entity at local midnight of `date`, via the history REST API.
// significant_changes_only MUST be false: with true, HA strips most entries
// and often returns nothing at all even though the data exists.
export async function fetchMidnightValue({ baseUrl, token, entityId, date = new Date() }) {
  const midnight = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const end = new Date(midnight.getTime() + 5 * 60 * 1000);
  const url = `${baseUrl}/api/history/period/${midnight.toISOString()}`
    + `?filter_entity_id=${encodeURIComponent(entityId)}`
    + `&end_time=${encodeURIComponent(end.toISOString())}`
    + '&minimal_response=true&significant_changes_only=false';
  try {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) return null;
    const data = await res.json();
    const v = Number.parseFloat(data?.[0]?.[0]?.state);
    return Number.isFinite(v) ? v : null;
  } catch {
    return null;
  }
}

// current − baseline, or null when the baseline can't be a real meter reading.
// A cloud integration that loses a device often parks the sensor on a bogus
// value (0, -0.001) for days; if midnight falls in that window the "today"
// figure becomes the whole lifetime total. Rejecting baseline <= 0 or
// baseline > current trades one blank day after a counter reset for never
// showing an absurd number.
export function todayDelta(rawCurrent, baseline, decimals = 2) {
  const current = Number.parseFloat(rawCurrent);
  if (!Number.isFinite(current) || !Number.isFinite(baseline)) return null;
  if (baseline <= 0 || baseline > current) return null;
  const f = 10 ** decimals;
  return Math.round((current - baseline) * f) / f;
}
