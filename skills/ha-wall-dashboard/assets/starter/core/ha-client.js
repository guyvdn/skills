import {
  buildAuth, buildGetStates, buildSubscribe, buildCallService, buildPing, backoffDelay,
} from './ws-protocol.js';

// REST: calendar events are not on the WebSocket state stream.
export async function getCalendarEvents({ baseUrl, token, entityId, start, end }) {
  const url = `${baseUrl}/api/calendars/${entityId}`
    + `?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`HA request failed: ${res.status} for ${entityId}`);
  return res.json();
}

// Open and keep a live WebSocket to HA: authenticate, snapshot with get_states,
// subscribe to state_changed, feed it all into `store`, reconnect with backoff.
// heartbeatMs > 0 adds a ping watchdog for half-open connections — always on
// for a wall tablet, off by default so unit tests stay timer-free.
export function connectLive({
  token,
  wsUrl,
  store,
  onStatus = () => {},
  WebSocketImpl = (typeof WebSocket !== 'undefined' ? WebSocket : null),
  scheduler = setTimeout,
  heartbeatMs = 0,
  heartbeatTimeoutMs = 10000,
}) {
  let socket = null;
  let nextId = 1;
  let attempt = 0;
  let closed = false;
  let pingTimer = null;
  let pongTimer = null;
  const pending = new Map(); // id -> resolve, for request/response commands

  const send = (obj) => socket.send(JSON.stringify(obj));
  const isOpen = () => socket && socket.readyState === 1;

  function stopHeartbeat() {
    if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
    if (pongTimer) { clearTimeout(pongTimer); pongTimer = null; }
  }

  // No pong in time = presume the link dead. Don't wait for close(): on a dead
  // link its handshake can take a minute before onclose fires. Detach the old
  // socket and go straight to the reconnect path.
  function startHeartbeat() {
    if (heartbeatMs <= 0) return;
    stopHeartbeat();
    pingTimer = setInterval(() => {
      if (!isOpen()) return;
      send(buildPing(nextId++));
      if (pongTimer) clearTimeout(pongTimer);
      pongTimer = setTimeout(dropSocket, heartbeatTimeoutMs);
    }, heartbeatMs);
  }

  function dropSocket() {
    const dead = socket;
    dead.onclose = dead.onmessage = dead.onerror = null;
    try { dead.close(); } catch { /* closing a dead socket can throw; nothing to do */ }
    lost();
  }

  function lost() {
    stopHeartbeat();
    for (const resolve of pending.values()) resolve(null);
    pending.clear();
    if (closed) return;
    onStatus('reconnecting');
    scheduler(open, backoffDelay(attempt++));
  }

  function open() {
    onStatus('connecting');
    socket = new WebSocketImpl(wsUrl);
    socket.onmessage = (ev) => handle(JSON.parse(ev.data));
    socket.onclose = lost;
    socket.onerror = () => { try { socket.close(); } catch { /* closing a dead socket can throw; nothing to do */ } };
  }

  function handle(msg) {
    if (msg.type === 'auth_required') {
      send(buildAuth(token));
    } else if (msg.type === 'auth_ok') {
      attempt = 0;
      send(buildGetStates(nextId++));
      send(buildSubscribe(nextId++));
      startHeartbeat();
    } else if (msg.type === 'auth_invalid') {
      closed = true; // bad token: stop instead of hammering HA, which bans IPs after failed logins
      stopHeartbeat();
      onStatus('auth_failed');
    } else if (msg.type === 'pong') {
      if (pongTimer) { clearTimeout(pongTimer); pongTimer = null; }
    } else if (msg.type === 'result' && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg.success ? msg.result : null);
    } else if (msg.type === 'result' && Array.isArray(msg.result)) {
      store.setAll(msg.result); // the get_states snapshot; other acks carry result:null
      onStatus('connected');
    } else if (msg.type === 'event') {
      store.applyEvent(msg.event);
    }
  }

  // Fire-and-forget. Returns false when the socket is down, so a tap that
  // never reached HA can be shown instead of silently swallowed.
  function callService(domain, service, target, serviceData) {
    if (!isOpen()) return false;
    send(buildCallService(nextId++, domain, service, target, serviceData));
    return true;
  }

  // Send any command and resolve with its `result` (null on failure or when
  // offline). `payload` is the command without an id,
  // e.g. { type: 'config/area_registry/list' }.
  function request(payload) {
    return new Promise((resolve) => {
      if (!isOpen()) { resolve(null); return; }
      const id = nextId++;
      pending.set(id, resolve);
      send({ ...payload, id });
    });
  }

  // For services that return data (weather.get_forecasts, calendar.get_events).
  async function callServiceForResponse(domain, service, target, serviceData) {
    if (!isOpen()) return null;
    const id = nextId++;
    const result = await new Promise((resolve) => {
      pending.set(id, resolve);
      send(buildCallService(id, domain, service, target, serviceData, true));
    });
    return result?.response ?? null;
  }

  function close() {
    closed = true;
    stopHeartbeat();
    try { socket?.close(); } catch { /* closing a dead socket can throw; nothing to do */ }
  }

  open();
  return { callService, callServiceForResponse, request, close };
}
