// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// Writes summary.json and a short summary.txt for load-run.sh, and prints the text.

export const TREND_STATS = ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'];

const SKIP = /^(data_sent|data_received|iteration_duration|iterations|vus|vus_max|http_req_(blocked|connecting|tls_handshaking|sending|waiting|receiving))/;

const ms = (value) => (value === undefined ? '-' : `${value.toFixed(1)}ms`);

function describe(metric) {
  const v = metric.values;
  if (metric.type === 'trend') {
    return `p50 ${ms(v.med)}  p95 ${ms(v['p(95)'])}  p99 ${ms(v['p(99)'])}  max ${ms(v.max)}  n ${v.count}`;
  }
  if (metric.type === 'rate') return `${(v.rate * 100).toFixed(2)}%`;
  if (metric.type === 'counter') return `${v.count}`;
  return `${v.value}`;
}

function thresholdLines(data) {
  const lines = [];
  for (const [name, metric] of Object.entries(data.metrics)) {
    for (const [rule, ok] of Object.entries(metric.thresholds || {})) {
      const passed = typeof ok === 'object' ? ok.ok : !ok;
      lines.push(`  ${passed ? 'pass' : 'FAIL'}  ${name}  ${rule}`);
    }
  }
  return lines;
}

export function buildSummary(scenario, data, notes) {
  const lines = [`${scenario}`, ...(notes || []), ''];
  for (const [name, metric] of Object.entries(data.metrics)) {
    if (SKIP.test(name)) continue;
    lines.push(`  ${name.padEnd(34)} ${describe(metric)}`);
  }
  lines.push('', 'thresholds', ...thresholdLines(data), '');
  const text = lines.join('\n');
  const dir = __ENV.RESULTS_DIR || '/results';
  return {
    stdout: text,
    [`${dir}/summary.txt`]: text,
    [`${dir}/summary.json`]: JSON.stringify(data, null, 2),
  };
}
