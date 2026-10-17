// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// N listeners hold sockets in one channel while M senders post at a set rate; times send to delivery.
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { baseUrl, intEnv, mintTicket, openSocket, seedWorld, sendMessage, sleepMs } from './lib/api.js';
import { buildSummary, TREND_STATS } from './lib/summary.js';

const LISTENERS = intEnv('LISTENERS', 100);
const SENDERS = intEnv('SENDERS', 5);
const RATE = intEnv('RATE', 2);
const DURATION = intEnv('DURATION', 30);
const USERS = intEnv('USERS', Math.max(SENDERS, Math.ceil(LISTENERS / 5), 10));
const CONNECT_GAP_MS = intEnv('CONNECT_GAP_MS', 20);
const SETTLE = 5;
const RAMP = Math.ceil((LISTENERS * CONNECT_GAP_MS) / 1000);
const TOTAL = RAMP + SETTLE + DURATION + SETTLE;

const deliveryMs = new Trend('delivery_ms', true);
const deliveries = new Counter('deliveries');
const sendsOk = new Counter('sends_ok');
const sendsFailed = new Counter('sends_failed');
const sendsLimited = new Counter('sends_rate_limited');
const listenersReady = new Counter('listeners_ready');
const connectFailed = new Counter('listener_connect_failed');
const closedEarly = new Counter('listener_closed_early');
const resyncFrames = new Counter('listener_resync_frames');

export const options = {
  setupTimeout: '10m',
  summaryTrendStats: TREND_STATS,
  scenarios: {
    listeners: { executor: 'per-vu-iterations', vus: LISTENERS, iterations: 1, maxDuration: `${TOTAL + 60}s`, exec: 'listen' },
    senders: { executor: 'per-vu-iterations', vus: SENDERS, iterations: 1, startTime: `${RAMP + SETTLE}s`, maxDuration: `${DURATION + 60}s`, exec: 'send' },
  },
  thresholds: {
    delivery_ms: ['p(95)<500', 'p(99)<1000'],
    listener_connect_failed: ['count==0'],
    listener_closed_early: ['count==0'],
    listener_resync_frames: ['count==0'],
    sends_failed: ['count==0'],
  },
};

export function setup() {
  const world = seedWorld({
    users: USERS, channels: 1, history: 5, password: `k6-load-${Date.now()}-pw`, runId: Date.now().toString(36),
  });
  return { users: world.users, channel: world.channels[0].id, epoch: Date.now() };
}

export async function listen(world) {
  const base = baseUrl();
  const index = exec.scenario.iterationInTest;
  await sleepMs(index * CONNECT_GAP_MS);
  const token = world.users[index % world.users.length].token;
  const minted = mintTicket(base, token);
  if (!minted.ticket) {
    connectFailed.add(1);
    return;
  }
  const closeAt = world.epoch + TOTAL * 1000;
  await new Promise((resolve) => {
    openSocket(base, minted.ticket, {
      ready: (ws) => {
        listenersReady.add(1);
        setTimeout(() => ws.close(), Math.max(0, closeAt - Date.now()));
      },
      frame: onFrame,
      failed: (_why, ws) => {
        connectFailed.add(1);
        ws.close();
      },
      closed: (wasReady) => {
        if (wasReady && Date.now() < closeAt - 1000) closedEarly.add(1);
        resolve();
      },
    });
  });
}

const SENT_AT = /"content":"lt:(\d+):/;

function onFrame(raw) {
  const sentAt = SENT_AT.exec(raw);
  if (sentAt !== null) {
    deliveryMs.add(Date.now() - Number(sentAt[1]));
    deliveries.add(1);
  } else if (raw.length < 200 && raw.indexOf('"type":"error"') !== -1) {
    resyncFrames.add(1);
  }
}

export async function send(world) {
  const base = baseUrl();
  const index = exec.scenario.iterationInTest;
  const token = world.users[index % world.users.length].token;
  const gapMs = 1000 / RATE;
  const stopAt = Date.now() + DURATION * 1000;
  for (let n = 0; Date.now() < stopAt; n += 1) {
    const started = Date.now();
    const res = sendMessage(base, token, world.channel, `lt:${started}:${index}:${n}`, { op: 'send' });
    if (res.status === 429) sendsLimited.add(1);
    else if (res.status === 200 || res.status === 201) sendsOk.add(1);
    else sendsFailed.add(1);
    await sleepMs(Math.max(0, gapMs - (Date.now() - started)));
  }
}

export function handleSummary(data) {
  const sent = data.metrics.sends_ok ? data.metrics.sends_ok.values.count : 0;
  const ready = data.metrics.listeners_ready ? data.metrics.listeners_ready.values.count : 0;
  const got = data.metrics.deliveries ? data.metrics.deliveries.values.count : 0;
  const expected = sent * ready;
  const notes = [
    `listeners ${LISTENERS}  senders ${SENDERS}  rate ${RATE}/s each  duration ${DURATION}s  users ${USERS}`,
    `offered ${SENDERS * RATE} msg/s into ${LISTENERS} listeners = ${SENDERS * RATE * LISTENERS} deliveries/s, for ${DURATION}s`,
    `deliveries ${got} of ${expected} expected (${expected ? ((got / expected) * 100).toFixed(2) : '-'}%)`,
    'delivery_ms runs from just before the send request to the frame arriving, so it includes the send round trip',
  ];
  return buildSummary('fanout', data, notes);
}
