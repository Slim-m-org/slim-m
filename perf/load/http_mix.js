// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// A REST read and write mix at a ramping arrival rate, to find the rate where p95 latency breaks.
import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { authed, baseUrl, intEnv, seedWorld, sendMessage } from './lib/api.js';
import { buildSummary, TREND_STATS } from './lib/summary.js';

const USERS = intEnv('USERS', 300);
const CHANNELS = intEnv('CHANNELS', 3);
const HISTORY = intEnv('HISTORY', 200);
const STEP_SECONDS = intEnv('STEP_SECONDS', 20);
const STAGE_RATES = (__ENV.STAGES || '50,100,200,400,800,1200').split(',').map(Number);
const MAX_VUS = intEnv('MAX_VUS', 1000);
const P95_BUDGET_MS = intEnv('P95_BUDGET_MS', 300);
const RAMP_SECONDS = 2;
const STAGE_SECONDS = RAMP_SECONDS + STEP_SECONDS;
const REACTIONS = ['\u{1F44D}', '\u{2764}\u{FE0F}', '\u{1F389}', '\u{1F440}'].map(encodeURIComponent);

// Cumulative weights: history 50, channels 15, send 20, react 15.
const MIX = [['history', 50], ['channels', 65], ['send', 85], ['react', 100]];

const opMs = new Trend('op_ms', true);
const limited = new Counter('rate_limited');
const serverErrors = new Counter('server_errors');

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 429));

export const options = {
  setupTimeout: '10m',
  summaryTrendStats: TREND_STATS,
  scenarios: {
    mix: {
      executor: 'ramping-arrival-rate',
      startRate: STAGE_RATES[0],
      timeUnit: '1s',
      preAllocatedVUs: Math.min(200, MAX_VUS),
      maxVUs: MAX_VUS,
      stages: STAGE_RATES.flatMap((target) => [
        { target, duration: `${RAMP_SECONDS}s` },
        { target, duration: `${STEP_SECONDS}s` },
      ]),
    },
  },
  thresholds: stageThresholds(),
};

// One p95 budget per rate step, so the first FAIL line is the knee.
function stageThresholds() {
  const thresholds = { server_errors: ['count==0'], dropped_iterations: ['count==0'] };
  ['channels', 'history', 'send', 'react'].forEach((op) => {
    thresholds[`op_ms{op:${op}}`] = [`p(95)<${P95_BUDGET_MS}`];
  });
  STAGE_RATES.forEach((_, stage) => {
    thresholds[`op_ms{stage:${stage}}`] = [`p(95)<${P95_BUDGET_MS}`];
  });
  return thresholds;
}

export function setup() {
  const world = seedWorld({
    users: USERS, channels: CHANNELS, history: HISTORY, password: `k6-load-${Date.now()}-pw`, runId: Date.now().toString(36),
  });
  return { users: world.users, channels: world.channels, epoch: Date.now() };
}

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

function chooseOp() {
  const roll = Math.random() * 100;
  return MIX.find(([, upTo]) => roll < upTo)[0];
}

function request(op, stage, call) {
  const res = call();
  if (res.status === 429) limited.add(1, { op });
  else if (res.status >= 500) serverErrors.add(1, { op });
  else opMs.add(res.timings.duration, { op, stage: String(stage) });
  return res;
}

export default function httpMix(world) {
  const base = baseUrl();
  const token = world.users[exec.scenario.iterationInTest % world.users.length].token;
  const channel = pick(world.channels);
  const op = chooseOp();
  const tags = { op };
  const stage = Math.min(STAGE_RATES.length - 1, Math.floor((Date.now() - world.epoch) / (STAGE_SECONDS * 1000)));
  if (op === 'channels') {
    request(op, stage, () => http.get(`${base}/channels`, authed(token, tags)));
  } else if (op === 'history') {
    const before = pick(channel.messages).seq + 1;
    request(op, stage, () => http.get(`${base}/channels/${channel.id}/messages?limit=50&before=${before}`, authed(token, tags)));
  } else if (op === 'send') {
    request(op, stage, () => sendMessage(base, token, channel.id, `mix ${exec.scenario.iterationInTest}`, tags));
  } else {
    const message = pick(channel.messages);
    request(op, stage, () => http.put(`${base}/messages/${message.id}/reactions/${pick(REACTIONS)}`, null, authed(token, tags)));
  }
}

export function handleSummary(data) {
  const notes = [
    `users ${USERS}  channels ${CHANNELS}  rate steps ${STAGE_RATES.join(',')} req/s, ${STEP_SECONDS}s each after a ${RAMP_SECONDS}s ramp`,
    'op_ms excludes 429s: a rate-limited request says nothing about the server, so it counts in rate_limited instead',
    '',
    'per step (target req/s, achieved req/s, latency of the answered requests)',
    ...STAGE_RATES.map((rate, stage) => stageLine(data, rate, stage)),
  ];
  return buildSummary('http_mix', data, notes);
}

function stageLine(data, rate, stage) {
  const metric = data.metrics[`op_ms{stage:${stage}}`];
  if (!metric) return `  ${String(rate).padStart(6)}  no requests answered`;
  const v = metric.values;
  const achieved = v.count / STAGE_SECONDS;
  return `  ${String(rate).padStart(6)}  ${achieved.toFixed(0).padStart(6)}  p50 ${v.med.toFixed(1)}ms  p95 ${v['p(95)'].toFixed(1)}ms  p99 ${v['p(99)'].toFixed(1)}ms`;
}
