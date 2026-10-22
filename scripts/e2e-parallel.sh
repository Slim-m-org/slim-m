#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The Python e2e suite on several stacks at once: scripts/e2e.sh per shard,
# each on its own ports, LiveKit container and work dir, the scenarios dealt
# across them by measured duration with scenarios that share state kept together.
#
# Usage: scripts/e2e-parallel.sh [--shards N|auto] [--plan] [--record] [--port-shift N]
#   --shards      how many stacks (default auto: up to 4, fewer on a small box)
#   --plan        print which scenarios go to which stack and stop
#   --record      on a clean run, rewrite scripts/lib/e2e_durations.json
#   --port-shift  move every port, to run beside another parallel run
#
# Environment: E2E_ONLY, E2E_REBUILD as for e2e.sh; E2E_PAR_WORK for the shards'
# directories (default ~/.cache/slimm-e2e/par). Exit status is non-zero if any scenario fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${E2E_PAR_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/slimm-e2e/par}"
export E2E_PAR_WORK="$WORK"

for arg in "$@"; do
  [[ "$arg" == "--plan" ]] && exec python3 -u "$ROOT/scripts/lib/e2e_parallel.py" "$@"
done

# Built once, here, so the shards share one server binary and one web bundle.
echo "== server =="
( cd "$ROOT" && SQLX_OFFLINE=true cargo build --release --bin slimm-server -q )
echo "== web build =="
WEB_DIR="$ROOT/client/packages/app/build/web"
bash "$ROOT/client/packages/app/tool/fetch_web_assets.sh"
# A bundle built before the sqlite3.wasm fetch cannot open the local store, so it is rebuilt too.
if [[ ! -f "$WEB_DIR/main.dart.js" || ! -f "$WEB_DIR/sqlite3.wasm" || -n "${E2E_REBUILD:-}" ]]; then
  rm -rf "$WEB_DIR"
  ( cd "$ROOT/client/packages/app" && flutter build web --release --no-web-resources-cdn )
fi
export E2E_WEB_DIR="${E2E_WEB_DIR:-$WEB_DIR}"
unset E2E_REBUILD

mkdir -p "$WORK"
exec python3 -u "$ROOT/scripts/lib/e2e_parallel.py" "$@"
