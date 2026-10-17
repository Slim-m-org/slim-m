// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// The slim-m API as the load scenarios need it: target guard, seeding, auth, tickets, frames.
import http from 'k6/http';
import { sleep } from 'k6';
import { WebSocket } from 'k6/websockets';

const LOOPBACK = /^(localhost|127(\.\d{1,3}){3}|\[::1\])$/;
const PRODUCTION = /(^|\.)npc-server\.top$|^10\.0\.0\.100$/;
const PROTOCOL = 1;
const HELLO_TIMEOUT_MS = 10000;

// Second line of defence: scripts/load-run.sh already refuses via scripts/lib/load_target.py.
export function baseUrl() {
  const raw = (__ENV.BASE_URL || 'http://127.0.0.1:8195').replace(/\/+$/, '');
  const host = (raw.match(/^https?:\/\/([^/:]+|\[[^\]]+\])/) || [])[1] || '';
  if (PRODUCTION.test(host) || !LOOPBACK.test(host)) {
    throw new Error(`refusing load target ${raw}: only a local disposable server is allowed`);
  }
  return raw;
}

export function intEnv(name, fallback) {
  const parsed = parseInt(__ENV[name], 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

export function uuid7() {
  const hex = (n, width) => n.toString(16).padStart(width, '0');
  const ms = Date.now();
  const rand = () => Math.floor(Math.random() * 0x10000);
  const variant = 0x8000 | (rand() & 0x3fff);
  return `${hex(Math.floor(ms / 0x10000), 8)}-${hex(ms % 0x10000, 4)}-7${hex(rand() & 0xfff, 3)}-` +
    `${hex(variant, 4)}-${hex(rand(), 4)}${hex(rand(), 4)}${hex(rand(), 4)}`;
}

export function authed(token, tags) {
  return {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    tags: tags || {},
  };
}

// The seeded server trusts one proxy hop, so a distinct address per call keeps the per-IP password bucket out of the way.
function fakeAddress(index) {
  return `10.${(index >> 16) & 255}.${(index >> 8) & 255}.${index & 255}`;
}

function post(base, path, body, params) {
  return http.post(`${base}${path}`, JSON.stringify(body), params);
}

function postRetrying(base, path, body, params) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const res = post(base, path, body, params);
    if (res.status !== 429) return res;
    sleep(Number(res.headers['Retry-After']) || 1);
  }
  throw new Error(`${path} stayed rate limited`);
}

function register(base, runId, index, password, inviteCode) {
  const body = {
    username: `lt${runId}u${index}`,
    display_name: `Load ${index}`,
    password,
    device_name: 'k6',
  };
  body.invite_code = inviteCode;
  const params = authed('', {});
  delete params.headers.Authorization;
  params.headers['X-Forwarded-For'] = fakeAddress(index + 1);
  const res = postRetrying(base, '/auth/register', body, params);
  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`register ${index} failed: ${res.status} ${res.body}`);
  }
  return res.json();
}

function createChannel(base, token, name) {
  const res = post(base, '/channels', { name, kind: 'text' }, authed(token));
  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`channel create failed: ${res.status} ${res.body}`);
  }
  return res.json().id;
}

export function sendMessage(base, token, channelId, content, tags) {
  return post(base, `/channels/${channelId}/messages`, { id: uuid7(), content }, authed(token, tags));
}

function seedHistory(base, accounts, channelId, count) {
  const messages = [];
  for (let n = 0; n < count; n += 1) {
    const res = sendMessage(base, accounts[n % accounts.length].token, channelId, `seed ${n}`);
    if (res.status === 429) {
      sleep(0.25);
      n -= 1;
    } else if (res.status === 200 || res.status === 201) {
      const body = res.json();
      messages.push({ id: body.id, seq: body.seq });
    }
  }
  return messages;
}

// The runner claims the fresh server and passes its owner token in; everyone else joins on one invite.
export function seedWorld({ users, channels, history, password, runId }) {
  const base = baseUrl();
  const owner = __ENV.OWNER_TOKEN;
  if (!owner) throw new Error('OWNER_TOKEN is not set; run this through scripts/load-run.sh');
  const invite = post(base, '/invites', { max_uses: users }, authed(owner)).json().code;
  const accounts = [];
  for (let index = 0; index < users; index += 1) {
    accounts.push({ token: register(base, runId, index, password, invite).access_token });
  }
  const world = { runId, users: accounts, channels: [] };
  for (let c = 0; c < channels; c += 1) {
    const id = createChannel(base, owner, `load-${runId}-${c}`);
    const messages = seedHistory(base, accounts, id, history);
    world.channels.push({ id, messages });
  }
  console.log(`load-start ${Date.now()}`);
  return world;
}

export function mintTicket(base, token) {
  const res = post(base, '/auth/ws-ticket', {}, authed(token, { op: 'ticket' }));
  return { status: res.status, ticket: res.status === 200 ? res.json().ticket : null, res };
}

export function wsUrl(base) {
  return `${base.replace(/^http/, 'ws')}/ws`;
}

// Opens a socket, sends hello, calls handlers.ready(ws) on the reply; later frames reach handlers.frame as raw text so a listener can skip the parse.
export function openSocket(base, ticket, handlers) {
  const ws = new WebSocket(wsUrl(base));
  let ready = false;
  const timer = setTimeout(() => {
    if (!ready) handlers.failed('hello_timeout', ws);
  }, HELLO_TIMEOUT_MS);
  ws.onopen = () => ws.send(JSON.stringify({ type: 'hello', ticket, protocol: PROTOCOL }));
  ws.onmessage = (event) => {
    if (!ready) {
      clearTimeout(timer);
      const frame = JSON.parse(event.data);
      if (frame.type !== 'hello') return handlers.failed(`first_frame_${frame.type}`, ws);
      ready = true;
      return handlers.ready(ws);
    }
    return handlers.frame(event.data, ws);
  };
  ws.onerror = () => {
    clearTimeout(timer);
    if (!ready) handlers.failed('socket_error', ws);
  };
  ws.onclose = () => {
    clearTimeout(timer);
    handlers.closed(ready, ws);
  };
  return ws;
}

export function sleepMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
