// Shared helpers for the skill scripts: finding the HA URL + token, and a
// promise-based WebSocket session. Node 22+ (global WebSocket and fetch).
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

// Project settings written by scaffold.mjs: { name, haUrl, deployTo }.
export function readProject(dir) {
  const p = join(resolve(dir), 'dashboard.project.json');
  return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : {};
}

// URL: --url, then $HA_URL, then dashboard.project.json.
// Token: --token is deliberately NOT supported (shell history); $HA_TOKEN,
// then the project's www/config.local.js.
export function resolveConnection({ url, project = '.' }) {
  const proj = readProject(project);
  const haUrl = (url ?? process.env.HA_URL ?? proj.haUrl ?? '').replace(/\/+$/, '');
  let token = process.env.HA_TOKEN ?? '';
  const local = join(resolve(project), 'www', 'config.local.js');
  if (!token && existsSync(local)) {
    token = readFileSync(local, 'utf8').match(/HA_TOKEN\s*=\s*['"]([^'"]+)['"]/)?.[1] ?? '';
  }
  if (!haUrl) fail('No Home Assistant URL. Pass --url http://homeassistant.local:8123 or set HA_URL.');
  if (!token || token.startsWith('PASTE_')) {
    fail('No token. Set HA_TOKEN, or paste one into www/config.local.js (HA profile -> Security -> Long-lived access tokens).');
  }
  return { haUrl, token };
}

export async function restGet(haUrl, token, path) {
  const res = await fetch(haUrl + path, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 401) fail('HA said 401: the token is wrong or revoked.');
  if (!res.ok) fail(`HA ${path} -> ${res.status} ${res.statusText}`);
  return res.json();
}

// Authenticated WebSocket with request(payload) -> result. Close when done.
export function wsSession(haUrl, token) {
  if (typeof WebSocket === 'undefined') fail('This script needs Node 22 or newer (global WebSocket).');
  const ws = new WebSocket(haUrl.replace(/^http/, 'ws') + '/api/websocket');
  let nextId = 1;
  const pending = new Map();
  return new Promise((resolveSession, rejectSession) => {
    const timer = setTimeout(() => rejectSession(new Error(`No answer from ${haUrl} within 15 s`)), 15000);
    ws.onerror = () => rejectSession(new Error(`Cannot open a WebSocket to ${haUrl}`));
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'auth_required') ws.send(JSON.stringify({ type: 'auth', access_token: token }));
      else if (msg.type === 'auth_invalid') { clearTimeout(timer); rejectSession(new Error('Token rejected (auth_invalid).')); }
      else if (msg.type === 'auth_ok') {
        clearTimeout(timer);
        resolveSession({
          haVersion: msg.ha_version,
          request(payload) {
            const id = nextId++;
            ws.send(JSON.stringify({ ...payload, id }));
            return new Promise((res, rej) => pending.set(id, { res, rej, type: payload.type }));
          },
          close: () => ws.close(),
        });
      } else if (msg.type === 'result' && pending.has(msg.id)) {
        const p = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.success) p.res(msg.result);
        else p.rej(new Error(`${p.type}: ${msg.error?.message ?? 'failed'}`));
      }
    };
  });
}

// Share paths as forward slashes: //host/config/www/x works on Windows too.
// Shells eat backslashes: Git Bash turns a quoted \\host\share into \host\share
// before Node sees it, which then reads as /host/share. Put that back when the
// first segment is clearly a host (an IP or a name with a dot).
export function normalizeShare(p) {
  let s = p.replaceAll('\\', '/');
  if (/^\/(\d{1,3}(\.\d{1,3}){3}|[\w-]+\.[\w.-]+)\//.test(s) && !s.startsWith('//')) s = '/' + s;
  return s;
}

export function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}
