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
# An interrupt stops every shard and tears its stack down.
#
# Usage: scripts/e2e-playwright-parallel.sh [spec-name ...]   (default: every spec)
#
# E2E_PW_WORK [~/.cache/slimm-e2e/pw]  must sit inside ~/.cache/slimm-e2e or e2e/.work
#
# Needs `npm ci` and `npx playwright install chromium` in e2e/ first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
SHIFT="${E2E_PORT_SHIFT:-0}"
export E2E_EVIDENCE="${E2E_EVIDENCE:-failure}"

WORK=""
specs=()
pids=()
finished=""

# Only a directory this script owns the contents of is ever emptied.
confine_work() {
  python3 "$ROOT/scripts/lib/safe_paths.py" confined "${E2E_PW_WORK:-$CACHE/slimm-e2e/pw}" \
    "$CACHE/slimm-e2e" "$ROOT/e2e/.work"
}

# Names become directories and a test filter, so none may climb out of $WORK.
check_spec_names() {
  local spec
  for spec in "${specs[@]}"; do
    [[ "$spec" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo "not a spec name: $spec" >&2; return 1; }
  done
}

shard_env() {
  local i="$1"
  export E2E_WORK="$WORK/${specs[$i]}/stack" E2E_PW_OUT="$WORK/${specs[$i]}"
  export E2E_API_PORT=$((28600 + SHIFT + i)) E2E_WEB_PORT=$((28700 + SHIFT + i))
  export E2E_LK_PORT=$((28800 + SHIFT + i)) E2E_RTC_TCP_PORT=$((28900 + SHIFT + i))
  export E2E_RTC_UDP_START=$((29400 + SHIFT + i * 60)) E2E_RTC_UDP_END=$((29450 + SHIFT + i * 60))
  export E2E_LK_CONTAINER="slimm-e2e-pw-$i"
}

port_busy() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

busy_ports() (
  shard_env "$1"
  for port in "$E2E_API_PORT" "$E2E_WEB_PORT" "$E2E_LK_PORT" "$E2E_RTC_TCP_PORT"; do
    if port_busy "$port"; then echo -n "$port "; fi
  done
)

# A stack already on a port answers as a build this run did not compile.
check_ports_free() {
  local i busy
  for i in "${!specs[@]}"; do
    busy="$(busy_ports "$i")"
    if [[ -n "$busy" ]]; then
      echo "ports already in use, so another run is up: ${busy}(${specs[$i]})" >&2
      return 1
    fi
  done
}

# Each shard is its own process group (set -m), so one signal reaches npx, node and the workers.
stop_shards() {
  local pid i
  for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
  for i in "${!specs[@]}"; do
    ( shard_env "$i"; bash "$ROOT/scripts/e2e-stack.sh" down ) || true
  done
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  [[ -n "$finished" ]] || stop_shards
  exit "$code"
}

# The server and the web bundle are built once and shared.
build_once() {
  local web_dir="$ROOT/client/packages/app/build/web"
  ( cd "$ROOT" && SQLX_OFFLINE=true cargo build --release --bin slimm-server -q )
  bash "$ROOT/client/packages/app/tool/fetch_web_assets.sh"
  if [[ ! -f "$web_dir/main.dart.js" || -n "${E2E_REBUILD:-}" ]]; then
    rm -rf "$web_dir"
    ( cd "$ROOT/client/packages/app" && flutter build web --release --no-web-resources-cdn )
  fi
  export E2E_WEB_DIR="${E2E_WEB_DIR:-$web_dir}"
  unset E2E_REBUILD
  export E2E_SKIP_SERVER_BUILD=1
}

run_shard() {
  local i="$1" begin=$SECONDS code=0
  shard_env "$i"
  cd "$ROOT/e2e"
  npx playwright test "${specs[$i]}" > "$E2E_PW_OUT/run.log" 2>&1 || code=$?
  echo "$code $((SECONDS - begin))" > "$E2E_PW_OUT/result"
}

report() {
  local started="$1" fail=0 spec code took summary
  echo "== playwright, ${#specs[@]} stacks, $((SECONDS - started))s wall =="
  for spec in "${specs[@]}"; do
    read -r code took < "$WORK/$spec/result" || { code=1; took=0; }
    summary="$(grep -E '^ +[0-9]+ (passed|failed|skipped|flaky)' "$WORK/$spec/run.log" | tr -s ' ' | paste -sd, - || true)"
    echo "  $spec: exit $code, ${took}s ${summary}"
    [[ "$code" == "0" ]] || fail=1
  done
  return $fail
}

main() {
  local file pid i started=$SECONDS
  WORK="$(confine_work)"
  specs=("$@")
  if [[ ${#specs[@]} -eq 0 ]]; then
    for file in "$ROOT"/e2e/src/tests/*.spec.ts; do specs+=("$(basename "$file" .spec.ts)"); done
  fi
  check_spec_names
  check_ports_free
  build_once

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p "$WORK"
  set -m
  for i in "${!specs[@]}"; do
    rm -rf "${WORK:?}/${specs[$i]}"
    mkdir -p "$WORK/${specs[$i]}"
    run_shard "$i" &
    pids+=($!)
    sleep 3
  done
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  set +m
  finished=1

  report "$started"
}

# Sourced, not run, by the tests that drive one function at a time.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
