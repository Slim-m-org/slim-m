#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Cold-start time and idle memory for the client, measured against the web
# build in a real headless `google-chrome-stable`, driven over the Chrome
# DevTools Protocol by scripts/lib/client_startup_probe.py.
#
# This measures the web build, not the Linux desktop build: headless Chrome
# opens no window on any display, so it needs no Xvfb and runs the same on a
# bare host or in CI. The native bundle under Xvfb is smoke-tested by
# scripts/desktop-shell-smoke.sh.
#
# Usage: scripts/measure-client-startup.sh [--runs N] [--rebuild] [--out PATH]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_PORT="${CLIENT_STARTUP_WEB_PORT:-8357}"
RUNS=3
REBUILD=0
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

need() { local tool="$1"; command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }; }
need flutter; need python3; need curl
CHROME="$(command -v google-chrome-stable || command -v google-chrome || true)"
[[ -n "$CHROME" ]] || { echo "missing: google-chrome-stable" >&2; exit 1; }
python3 -c "import websocket" 2>/dev/null || {
  echo "missing python package: pip install --user websocket-client" >&2; exit 1; }

WEB_DIR="$ROOT/client/packages/app/build/web"

cleanup() {
  local code=$?
  if [[ -n "${WEB_PID:-}" ]]; then kill "$WEB_PID" 2>/dev/null || true; fi
  exit $code
}
trap cleanup EXIT

echo "== web build =="
bash "$ROOT/client/packages/app/tool/fetch_web_assets.sh"
if [[ ! -f "$WEB_DIR/main.dart.js" || "$REBUILD" -eq 1 ]]; then
  # flutter never re-syncs a new web/ file into an existing build/web (see scripts/e2e.sh)
  rm -rf "$WEB_DIR"
  ( cd "$ROOT/client/packages/app" && flutter build web --release )
fi

if curl -sf -o /dev/null "http://localhost:$WEB_PORT/" 2>/dev/null; then
  echo "port $WEB_PORT is already serving something; stop that first" >&2
  exit 1
fi
python3 -m http.server "$WEB_PORT" --directory "$WEB_DIR" >/dev/null 2>&1 &
WEB_PID=$!
for asset in main.dart.js flutter_bootstrap.js sqlite3.wasm drift_worker.js; do
  served=0
  for _ in $(seq 20); do
    curl -sf -o /dev/null "http://localhost:$WEB_PORT/$asset" && { served=1; break; }
    sleep 1
  done
  [[ $served -eq 1 ]] || { echo "the web build does not serve $asset" >&2; exit 1; }
done

echo "== $RUNS cold-start run(s) against http://localhost:$WEB_PORT =="
RESULT_JSON="$(python3 "$ROOT/scripts/lib/client_startup_probe.py" \
  "http://localhost:$WEB_PORT" "$RUNS")"
echo "$RESULT_JSON"

[[ -n "$OUT" ]] && printf '%s\n' "$RESULT_JSON" > "$OUT" && echo "wrote $OUT"

python3 - "$RESULT_JSON" <<'PYEOF'
import json
import statistics
import sys

runs = json.loads(sys.argv[1])


def median(key):
    values = [r[key] for r in runs if r.get(key) is not None]
    return round(statistics.median(values)) if values else None


print()
print("== median across", len(runs), "run(s) ==")
print(f"  cold start (interactive) : {median('cold_start_interactive_ms')} ms")
print(f"  JS heap                  : {median('heap_kb')} kB "
      f"(+{median('heap_over_baseline_kb')} kB over an idle chrome tab)")
print(f"  process tree Pss         : {median('pss_tree_kb')} kB "
      f"(+{median('pss_over_baseline_kb')} kB over an idle chrome tab)")
PYEOF
