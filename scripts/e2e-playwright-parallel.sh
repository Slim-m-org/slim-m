#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The Playwright suite in e2e/ with one spec file per stack, all at once.
#
# Each spec file is a self-contained story against its own seeded deployment, so
# a stack per file runs them side by side: own ports, LiveKit container and work
# directory, own results and report under $E2E_PW_WORK/<spec>. Exits non-zero if
# any spec fails. Video, trace and screenshots are kept for failures only unless
# E2E_EVIDENCE=on; a serial `npm test` in e2e/ is unchanged and is what CI runs.
#
# Usage: scripts/e2e-playwright-parallel.sh [spec-name ...]   (default: every spec)
#
# Needs `npm ci` and `npx playwright install chromium` in e2e/ first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${E2E_PW_WORK:-/tmp/e2e-pw}"
SHIFT="${E2E_PORT_SHIFT:-0}"
export E2E_EVIDENCE="${E2E_EVIDENCE:-failure}"

# The server and the web bundle are built once and shared.
( cd "$ROOT" && SQLX_OFFLINE=true cargo build --release --bin slimm-server -q )
WEB_DIR="$ROOT/client/packages/app/build/web"
bash "$ROOT/client/packages/app/tool/fetch_web_assets.sh"
if [[ ! -f "$WEB_DIR/main.dart.js" || -n "${E2E_REBUILD:-}" ]]; then
  rm -rf "$WEB_DIR"
  ( cd "$ROOT/client/packages/app" && flutter build web --release --no-web-resources-cdn )
fi
export E2E_WEB_DIR="${E2E_WEB_DIR:-$WEB_DIR}"
unset E2E_REBUILD
export E2E_SKIP_SERVER_BUILD=1

specs=("$@")
if [[ ${#specs[@]} -eq 0 ]]; then
  for file in "$ROOT"/e2e/src/tests/*.spec.ts; do
    name="$(basename "$file" .spec.ts)"
    specs+=("$name")
  done
fi

rm -rf "$WORK"; mkdir -p "$WORK"
pids=(); started=$SECONDS
for i in "${!specs[@]}"; do
  spec="${specs[$i]}"
  dir="$WORK/$spec"; mkdir -p "$dir"
  (
    export E2E_WORK="$dir/stack" E2E_PW_OUT="$dir"
    export E2E_API_PORT=$((28600 + SHIFT + i)) E2E_WEB_PORT=$((28700 + SHIFT + i))
    export E2E_LK_PORT=$((28800 + SHIFT + i)) E2E_RTC_TCP_PORT=$((28900 + SHIFT + i))
    export E2E_RTC_UDP_START=$((29400 + SHIFT + i * 60)) E2E_RTC_UDP_END=$((29450 + SHIFT + i * 60))
    export E2E_LK_CONTAINER="slimm-e2e-pw-$i"
    cd "$ROOT/e2e"
    begin=$SECONDS
    code=0
    npx playwright test "$spec" > "$dir/run.log" 2>&1 || code=$?
    echo "$code $((SECONDS - begin))" > "$dir/result"
  ) &
  pids+=($!)
  sleep 3
done

for pid in "${pids[@]}"; do wait "$pid" || true; done

fail=0
echo "== playwright, ${#specs[@]} stacks, $((SECONDS - started))s wall =="
for spec in "${specs[@]}"; do
  read -r code took < "$WORK/$spec/result" || { code=1; took=0; }
  summary="$(grep -E '^ +[0-9]+ (passed|failed|skipped|flaky)' "$WORK/$spec/run.log" | tr -s ' ' | paste -sd, - || true)"
  echo "  $spec: exit $code, ${took}s ${summary}"
  [[ "$code" == "0" ]] || fail=1
done
exit $fail
