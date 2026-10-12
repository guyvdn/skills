import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StateStore } from '../core/state-store.js';
import { buildCallService, backoffDelay } from '../core/ws-protocol.js';
import { connectLive } from '../core/ha-client.js';
import { todayDelta } from '../core/history.js';
import { num, displayUnit } from '../core/format.js';
import { translator, timeZoneNotice } from '../core/i18n.js';

test('store: subscribe fires immediately, then on change', () => {
  const store = new StateStore();
  const seen = [];
  store.subscribe(['light.a'], (s) => seen.push(s?.state ?? null));
  store.setAll([{ entity_id: 'light.a', state: 'off' }]);
  store.applyEvent({ data: { new_state: { entity_id: 'light.a', state: 'on' } } });
  assert.deepEqual(seen, [null, 'off', 'on']);
});

test('ws: service data and return_response only when given', () => {
  assert.deepEqual(buildCallService(1, 'light', 'toggle', { entity_id: 'light.a' }),
    { id: 1, type: 'call_service', domain: 'light', service: 'toggle', target: { entity_id: 'light.a' } });
  const c = buildCallService(2, 'weather', 'get_forecasts', { entity_id: 'weather.x' }, { type: 'daily' }, true);
  assert.equal(c.return_response, true);
  assert.deepEqual(c.service_data, { type: 'daily' });
});

test('ws: backoff caps at 30 s', () => {
  assert.equal(backoffDelay(0), 1000);
  assert.equal(backoffDelay(10), 30000);
});

// Minimal fake socket: records sent frames, lets the test push server frames.
function fakeSocketClass(log) {
  return class {
    constructor() { this.readyState = 1; log.socket = this; }
    send(s) { log.sent.push(JSON.parse(s)); }
    close() { this.readyState = 3; this.onclose?.(); }
    push(msg) { this.onmessage({ data: JSON.stringify(msg) }); }
  };
}

test('client: auth -> snapshot -> connected, events reach the store', () => {
  const log = { sent: [] };
  const store = new StateStore();
  const statuses = [];
  connectLive({ token: 'T', wsUrl: 'ws://x', store, WebSocketImpl: fakeSocketClass(log), onStatus: (s) => statuses.push(s) });
  log.socket.push({ type: 'auth_required' });
  assert.deepEqual(log.sent[0], { type: 'auth', access_token: 'T' });
  log.socket.push({ type: 'auth_ok' });
  const getStates = log.sent.find((m) => m.type === 'get_states');
  log.socket.push({ type: 'result', id: getStates.id, success: true, result: [{ entity_id: 'sun.sun', state: 'above_horizon' }] });
  assert.equal(store.get('sun.sun').state, 'above_horizon');
  assert.deepEqual(statuses, ['connecting', 'connected']);
});

test('client: auth_invalid stops reconnecting', () => {
  const log = { sent: [] };
  let scheduled = 0;
  connectLive({ token: 'bad', wsUrl: 'ws://x', store: new StateStore(), WebSocketImpl: fakeSocketClass(log), scheduler: () => { scheduled++; } });
  log.socket.push({ type: 'auth_invalid' });
  log.socket.close();
  assert.equal(scheduled, 0);
});

test('client: callServiceForResponse resolves with the response payload', async () => {
  const log = { sent: [] };
  const client = connectLive({ token: 'T', wsUrl: 'ws://x', store: new StateStore(), WebSocketImpl: fakeSocketClass(log) });
  const p = client.callServiceForResponse('weather', 'get_forecasts', { entity_id: 'weather.x' }, { type: 'daily' });
  const frame = log.sent.at(-1);
  log.socket.push({ type: 'result', id: frame.id, success: true, result: { response: { 'weather.x': { forecast: [1] } } } });
  assert.deepEqual(await p, { 'weather.x': { forecast: [1] } });
});

test('todayDelta: normal day', () => {
  assert.equal(todayDelta('1234.56', 1230.06), 4.5);
});

test('todayDelta: rejects a bogus baseline instead of showing the lifetime total', () => {
  assert.equal(todayDelta('246.8', -0.001), null);
  assert.equal(todayDelta('246.8', 0), null);
  assert.equal(todayDelta('10', 500), null); // counter reset
  assert.equal(todayDelta('unavailable', 10), null);
  assert.equal(todayDelta('10', null), null);
});

test('num: unknown and unavailable are null, not NaN or 0', () => {
  assert.equal(num('unavailable'), null);
  assert.equal(num(''), null);
  assert.equal(num(null), null);
  assert.equal(num('21.5'), 21.5);
});

test('displayUnit: temperatures become a raised degree', () => {
  assert.deepEqual(displayUnit('°C'), { unit: '°', sup: true });
  assert.deepEqual(displayUnit('kWh'), { unit: 'kWh', sup: false });
});

test('i18n: language fallback and overrides', () => {
  assert.equal(translator('nl-BE')('allDay'), 'Hele dag');
  assert.equal(translator('pt-PT')('allDay'), 'All day');
  assert.equal(translator('en', { allDay: 'Whole day' })('allDay'), 'Whole day');
});

test('client: a missed pong reconnects at once, without waiting for onclose', async () => {
  const log = { sent: [] };
  const sockets = [];
  class Sock {
    constructor() { this.readyState = 1; sockets.push(this); log.socket = this; }
    send(s) { log.sent.push(JSON.parse(s)); }
    close() { /* a dead link: the close handshake never completes, onclose never fires */ }
    push(msg) { this.onmessage({ data: JSON.stringify(msg) }); }
  }
  const scheduled = [];
  const client = connectLive({ token: 'T', wsUrl: 'ws://x', store: new StateStore(), WebSocketImpl: Sock,
    scheduler: (fn) => scheduled.push(fn), heartbeatMs: 5, heartbeatTimeoutMs: 5 });
  sockets[0].push({ type: 'auth_required' });
  sockets[0].push({ type: 'auth_ok' });
  await new Promise((r) => setTimeout(r, 40));
  client.close();
  assert.ok(scheduled.length >= 1, 'a reconnect was scheduled');
  assert.equal(sockets[0].onmessage, null, 'the dead socket was detached');
});

test('timeZoneNotice: same offset is fine, a different one warns', () => {
  const t = translator('en');
  const winter = new Date('2026-01-15T12:00:00Z');
  assert.equal(timeZoneNotice(t, 'Europe/Brussels', 'Europe/Brussels', winter), null);
  assert.equal(timeZoneNotice(t, 'Europe/Amsterdam', 'Europe/Brussels', winter), null);
  assert.equal(timeZoneNotice(t, 'UTC', 'Europe/Brussels', winter), 'Tablet time zone UTC ≠ Home Assistant Europe/Brussels');
  assert.equal(timeZoneNotice(t, 'UTC', undefined, winter), null);
});
