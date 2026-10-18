// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// The routes the admin analytics page lists as slowest: attachment download with and without ?w=, upload, and the voice roster.
import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { authed, baseUrl, intEnv, seedWorld, uuid7 } from './lib/api.js';
import { buildSummary, TREND_STATS } from './lib/summary.js';

const USERS = intEnv('USERS', 20);
const COLD_PHOTOS = intEnv('COLD_PHOTOS', 8);
const COLD_START = intEnv('COLD_START', 0);
const ORIGINAL_RATE = intEnv('ORIGINAL_RATE', 4);
const PREVIEW_RATE = intEnv('PREVIEW_RATE', 40);
const WARM_SECONDS = intEnv('WARM_SECONDS', 20);
const ROSTER_RATE = intEnv('ROSTER_RATE', 100);
const PHOTO = open(`/fixtures/${__ENV.PHOTO || 'photo-6000x4000.jpg'}`, 'b');

const coldMs = new Trend('cold_preview_ms', true);
const warmMs = new Trend('op_ms', true);
const uploadMs = new Trend('upload_ms', true);
const limited = new Counter('rate_limited');
const serverErrors = new Counter('server_errors');

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 399 }, 429));

function arrivals(exec, rate) {
  return {
    executor: 'constant-arrival-rate', exec, rate, timeUnit: '1s', duration: `${WARM_SECONDS}s`,
    startTime: '40s', preAllocatedVUs: 20, maxVUs: 100,
  };
}

export const options = {
  setupTimeout: '10m',
  summaryTrendStats: TREND_STATS,
  scenarios: {
    cold: { executor: 'per-vu-iterations', exec: 'cold', vus: COLD_PHOTOS, iterations: 1, maxDuration: '5m', startTime: `${COLD_START}s` },
    warm_original: arrivals('warmOriginal', ORIGINAL_RATE),
    warm_w320: arrivals('warmW320', PREVIEW_RATE),
    warm_w640: arrivals('warmW640', PREVIEW_RATE / 2),
    roster: { ...arrivals('roster', ROSTER_RATE), maxVUs: 200 },
  },
  thresholds: {
    server_errors: ['count==0'],
    ...Object.fromEntries(['original', 'w320', 'w640', 'roster'].map((op) => [`op_ms{op:${op}}`, ['p(95)<500']])),
    'cold_preview_ms{op:cold_w320}': ['p(95)<2000'],
  },
};

// A different trailing byte string per photo gives a different content hash without touching the picture.
function variant(tag) {
  const tail = new Uint8Array(16).fill(tag);
  const joined = new Uint8Array(PHOTO.byteLength + tail.length);
  joined.set(new Uint8Array(PHOTO), 0);
  joined.set(tail, PHOTO.byteLength);
  return joined.buffer;
}

function upload(base, token, body, name) {
  const res = http.post(`${base}/attachments?filename=${name}`, body, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream' }, tags: { op: 'upload' },
  });
  if (res.status >= 500) serverErrors.add(1, { op: 'upload' });
  if (res.status !== 201) throw new Error(`upload failed: ${res.status} ${res.body}`);
  uploadMs.add(res.timings.duration);
  return res.json().id;
}

export function setup() {
  const world = seedWorld({ users: USERS, channels: 1, history: 5, password: `k6-routes-${Date.now()}-pw`, runId: Date.now().toString(36) });
  const base = baseUrl();
  const token = world.users[0].token;
  const ids = [];
  for (let n = 0; n < COLD_PHOTOS + 1; n += 1) ids.push(upload(base, token, variant(n + 1), `photo-${n}.jpg`));
  const channel = world.channels[0].id;
  ids.forEach((id) => {
    const res = http.post(`${base}/channels/${channel}/messages`, JSON.stringify({ id: uuid7(), content: 'photo', attachment_ids: [id] }), authed(token));
    if (res.status !== 200 && res.status !== 201) throw new Error(`attach failed: ${res.status} ${res.body}`);
  });
  return { tokens: world.users.map((user) => user.token), channel, ids };
}

function get(base, world, path, tags) {
  const token = world.tokens[exec.scenario.iterationInTest % world.tokens.length];
  const params = authed(token, tags);
  params.responseType = 'none';
  const res = http.get(`${base}${path}`, params);
  if (res.status === 429) limited.add(1, tags);
  else if (res.status !== 200) serverErrors.add(1, tags);
  return res;
}

// Each virtual user asks for a different photo's first preview at once, as an open channel's image grid does.
export function cold(world) {
  const id = world.ids[exec.vu.idInTest % COLD_PHOTOS];
  const res = get(baseUrl(), world, `/attachments/${id}?w=320`, { op: 'cold_w320' });
  if (res.status === 200) coldMs.add(res.timings.duration, { op: 'cold_w320' });
}

// The warm photos were all previewed by the cold burst, so these read what a repeat viewer gets.
function warm(world, op, query) {
  const id = world.ids[exec.scenario.iterationInTest % COLD_PHOTOS];
  const res = get(baseUrl(), world, `/attachments/${id}${query}`, { op });
  if (res.status === 200) warmMs.add(res.timings.duration, { op });
}

export function warmOriginal(world) {
  warm(world, 'original', '');
}

export function warmW320(world) {
  warm(world, 'w320', '?w=320');
}

export function warmW640(world) {
  warm(world, 'w640', '?w=640');
}

export function roster(world) {
  const res = get(baseUrl(), world, `/channels/${world.channel}/voice/roster`, { op: 'roster' });
  if (res.status === 200) warmMs.add(res.timings.duration, { op: 'roster' });
}

export function handleSummary(data) {
  const notes = [
    `photo ${__ENV.PHOTO || 'photo-6000x4000.jpg'}  cold previews ${COLD_PHOTOS} at once, then ${WARM_SECONDS}s of original ${ORIGINAL_RATE}/s, previews ${PREVIEW_RATE}/s and roster ${ROSTER_RATE}/s`,
    'link previews are not driven here: the SSRF guard refuses a loopback fake page, so they are timed by the integration tests',
  ];
  return buildSummary('routes', data, notes);
}
