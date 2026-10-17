// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Every client drops at the same instant, then reconnects and resyncs at once, round after round.
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';
import { authed, baseUrl, intEnv, mintTicket, openSocket, seedWorld, sleepMs } from './lib/api.js';
import { buildSummary, TREND_STATS } from './lib/summary.js';

const CLIENTS = intEnv('CLIENTS', 200);
const ROUNDS = intEnv('ROUNDS', 3);
const HOLD = intEnv('HOLD', 10);
const JITTER_MS = intEnv('JITTER_MS', 0);
const LAG = intEnv('LAG', 20);
const USERS = intEnv('USERS', Math.max(10, Math.ceil(CLIENTS / 4)));

const ticketMs = new Trend('ticket_ms', true);
const helloMs = new Trend('hello_ms', true);
const syncMs = new Trend('sync_ms', true);
const readyMs = new Trend('time_to_usable_ms', true);
const ticketLimited = new Counter('ticket_rate_limited');
const connectFailed = new Counter('connect_failed');
const syncFailed = new Counter('sync_failed');
const dropped = new Counter('dropped_while_held');
const rounds = new Counter('rounds_completed');

export const options = {
  setupTimeout: '10m',
  summaryTrendStats: TREND_STATS,
  scenarios: {
    storm: {
      executor: 'per-vu-iterations',
      vus: CLIENTS,
      iterations: 1,
      maxDuration: `${(ROUNDS + 1) * (HOLD + 30) + 60}s`,
    },
  },
  thresholds: {
    time_to_usable_ms: ['p(95)<2000', 'p(99)<5000'],
    connect_failed: ['count==0'],
    sync_failed: ['count==0'],
    dropped_while_held: ['count==0'],
  },
};

export function setup() {
  const world = seedWorld({
    users: USERS, channels: 3, history: LAG * 2, password: `k6-load-${Date.now()}-pw`, runId: Date.now().toString(36),
  });
  const scopes = world.channels.map((c) => ({
    channel_id: c.id,
    after_seq: Math.max(0, Math.max(...c.messages.map((m) => m.seq)) - LAG),
  }));
  return { users: world.users, scopes, epoch: Date.now() };
}

async function ticketWithRetry(base, token) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const minted = mintTicket(base, token);
    ticketMs.add(minted.res.timings.duration);
    if (minted.ticket) return minted.ticket;
    if (minted.status !== 429) return null;
    ticketLimited.add(1);
    await sleepMs(1000 + Math.random() * 500);
  }
  return null;
}

function connect(base, ticket) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    openSocket(base, ticket, {
      ready: (ws) => {
        helloMs.add(Date.now() - startedAt);
        resolve(ws);
      },
      frame: () => {},
      failed: (why, ws) => {
        ws.close();
        resolve(why);
      },
      closed: (wasReady, ws) => {
        if (wasReady && ws.held) dropped.add(1);
      },
    });
  });
}

export default async function (world) {
  const base = baseUrl();
  const token = world.users[exec.scenario.iterationInTest % world.users.length].token;
  const origin = world.epoch;
  for (let round = 0; round < ROUNDS; round += 1) {
    const barrier = origin + round * HOLD * 1000;
    await sleepMs(Math.max(0, barrier - Date.now()) + Math.random() * JITTER_MS);
    const begun = Date.now();
    const ticket = await ticketWithRetry(base, token);
    const ws = ticket ? await connect(base, ticket) : 'no_ticket';
    if (typeof ws === 'string') {
      connectFailed.add(1, { reason: ws });
      continue;
    }
    const sync = http.post(`${base}/sync`, JSON.stringify({ scopes: world.scopes }), authed(token, { op: 'sync' }));
    syncMs.add(sync.timings.duration);
    if (sync.status !== 200) syncFailed.add(1);
    readyMs.add(Date.now() - begun);
    rounds.add(1);
    ws.held = true;
    await sleepMs(Math.max(0, origin + (round + 1) * HOLD * 1000 - Date.now()));
    ws.held = false;
    ws.close();
  }
}

export function handleSummary(data) {
  const notes = [
    `clients ${CLIENTS}  rounds ${ROUNDS}  hold ${HOLD}s  jitter ${JITTER_MS}ms  users ${USERS}`,
    'time_to_usable_ms is ticket + hello + sync, from the shared barrier to a client that could show messages',
  ];
  return buildSummary('connect_storm', data, notes);
}
