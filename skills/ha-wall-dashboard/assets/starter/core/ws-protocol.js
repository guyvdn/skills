// Pure helpers for the Home Assistant WebSocket protocol.
// https://developers.home-assistant.io/docs/api/websocket
// Builders take the id from the caller (which owns the counter). No socket, no
// state, so all of this is unit-testable in Node.

export function buildAuth(token) {
  return { type: 'auth', access_token: token };
}

export function buildGetStates(id) {
  return { id, type: 'get_states' };
}

export function buildSubscribe(id) {
  return { id, type: 'subscribe_events', event_type: 'state_changed' };
}

// App-level heartbeat. HA answers { type: 'pong', id }. Catches a half-open
// connection (wifi drops, router reboots) where onclose never fires by itself.
export function buildPing(id) {
  return { id, type: 'ping' };
}

// serviceData is the service payload (e.g. { temperature: 21.5 }); HA wants it
// in `service_data`, separate from `target` (entity/device/area ids only).
// returnResponse is for services that answer, like weather.get_forecasts.
export function buildCallService(id, domain, service, target, serviceData, returnResponse = false) {
  const cmd = { id, type: 'call_service', domain, service, target };
  if (serviceData) cmd.service_data = serviceData;
  if (returnResponse) cmd.return_response = true;
  return cmd;
}

// Exponential backoff with a ceiling: 1s, 2s, 4s, 8s, 16s, 30s, 30s, ...
export function backoffDelay(attempt) {
  return Math.min(1000 * 2 ** attempt, 30000);
}
