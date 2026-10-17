#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Boots a disposable local slimm-server and runs one k6 scenario against it.
# usage: scripts/load-run.sh [--profile] [--musl IMAGE | --binary PATH] [--no-build] <scenario> [k6 args]
#   scenario: fanout | http_mix | connect_storm (perf/load/<scenario>.js)
#   sizes:    pass k6 env flags after the scenario, e.g. -e LISTENERS=500 -e SENDERS=10
# Refuses any non-loopback target; there is no flag to point it elsewhere.
# LOAD_SERVER_CPUS / LOAD_K6_CPUS (for example 0-7 and 8-31) pin each side to its own cores.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
K6_IMAGE="grafana/k6@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34"
PORT="${LOAD_PORT:-8195}"
BASE="http://127.0.0.1:$PORT"
PROFILE=0
BUILD=1
MUSL_IMAGE=""
BINARY_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE=1; shift ;;
    --no-build) BUILD=0; shift ;;
    --musl) MUSL_IMAGE="${2:?--musl needs an image}"; shift 2 ;;
    --binary) BINARY_OVERRIDE="${2:?--binary needs a path}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
SCENARIO="${1:?usage: load-run.sh [--profile] [--musl IMAGE] <scenario> [k6 args]}"
shift
[[ -f "$ROOT/perf/load/$SCENARIO.js" ]] || { echo "no scenario perf/load/$SCENARIO.js" >&2; exit 2; }
if [[ -n "$MUSL_IMAGE" && -n "$BINARY_OVERRIDE" ]]; then
  echo "--musl and --binary are alternatives" >&2
  exit 2
fi
if [[ "$PROFILE" = 1 && -n "$MUSL_IMAGE" ]]; then
  echo "--profile needs a binary with symbols, not the stripped --musl one" >&2
  exit 2
fi

python3 "$ROOT/scripts/lib/load_target.py" "$BASE" >/dev/null
if curl -fsS -m 1 "$BASE/healthz" >/dev/null 2>&1; then
  echo "something already answers on $BASE; set LOAD_PORT to a free port" >&2
  exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="$ROOT/perf/load/results/$STAMP-$SCENARIO"
WORK="$RESULTS/work"
mkdir -p "$WORK/data"

build_binary() {
  local target
  if [[ -n "$BINARY_OVERRIDE" ]]; then
    echo "$BINARY_OVERRIDE"
    return
  fi
  if [[ -n "$MUSL_IMAGE" ]]; then
    local cid
    cid=$(docker create "$MUSL_IMAGE")
    docker cp "$cid:/usr/local/bin/slimm-server" "$WORK/slimm-server-musl"
    docker rm "$cid" >/dev/null
    echo "$WORK/slimm-server-musl"
    return
  fi
  target=$(cd "$ROOT" && cargo metadata --format-version 1 --no-deps |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
  if [[ "$PROFILE" = 1 ]]; then
    if [[ "$BUILD" = 1 ]]; then
      (cd "$ROOT" &&
        CARGO_PROFILE_PROFILING_INHERITS=release CARGO_PROFILE_PROFILING_DEBUG=line-tables-only \
          CARGO_PROFILE_PROFILING_STRIP=none SQLX_OFFLINE=true CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
          cargo build --profile profiling --bin slimm-server) >&2
    fi
    echo "$target/profiling/slimm-server"
  else
    if [[ "$BUILD" = 1 ]]; then
      (cd "$ROOT" && SQLX_OFFLINE=true CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
        cargo build --release --bin slimm-server) >&2
    fi
    echo "$target/release/slimm-server"
  fi
}

BINARY=$(build_binary)
[[ -x "$BINARY" ]] || { echo "no server binary at $BINARY" >&2; exit 1; }
KIND="glibc, release"
if [[ -n "$MUSL_IMAGE" ]]; then
  KIND="musl from $MUSL_IMAGE $(docker image inspect -f '{{index .RepoDigests 0}}' "$MUSL_IMAGE" 2>/dev/null || true)"
elif [[ -n "$BINARY_OVERRIDE" ]]; then
  KIND="prebuilt binary"
elif [[ "$PROFILE" = 1 ]]; then
  KIND="glibc, profiling profile (release plus symbols)"
fi
{
  echo "binary   $BINARY"
  echo "kind     $KIND"
  echo "commit   $(git -C "$ROOT" rev-parse --short HEAD)"
  echo "cpus     $(nproc)"
  echo "scenario $SCENARIO $*"
} | tee "$RESULTS/run.txt"

SERVER_PID=""
SAMPLER_PID=""
LAUNCHER_PID=""
stop_server() {
  [[ -z "${K6_NAME:-}" ]] || docker rm -f "$K6_NAME" >/dev/null 2>&1 || true
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  [[ -n "$LAUNCHER_PID" ]] && wait "$LAUNCHER_PID" 2>/dev/null || true
  SERVER_PID=""
  SAMPLER_PID=""
  LAUNCHER_PID=""
}
trap stop_server EXIT

export SLIMM_PORT="$PORT"
export SLIMM_DATABASE_PATH="$WORK/data/slimm.db"
export SLIMM_ATTACHMENTS_DIR="$WORK/data/media"
export SLIMM_TRUST_PROXY_HOPS=1
export SLIMM_LOG="${SLIMM_LOG:-warn}"
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

SAMPLY="${SAMPLY:-samply}"
# samply opens one perf buffer per cpu per thread, which exceeds the default mlock budget on a wide machine.
if [[ "$PROFILE" = 1 && -z "${LOAD_SERVER_CPUS:-}" && "$(nproc)" -gt 8 ]]; then
  LOAD_SERVER_CPUS=0-7
fi
PIN=()
[[ -z "${LOAD_SERVER_CPUS:-}" ]] || PIN=(taskset -c "$LOAD_SERVER_CPUS")
K6_PIN=()
[[ -z "${LOAD_K6_CPUS:-}" ]] || K6_PIN=(--cpuset-cpus "$LOAD_K6_CPUS")

if [[ "$PROFILE" = 1 ]]; then
  command -v "$SAMPLY" >/dev/null || { echo "samply missing: cargo install --locked samply" >&2; exit 1; }
  "${PIN[@]}" "$SAMPLY" record --save-only --unstable-presymbolicate -r 1000 -o "$RESULTS/profile.json.gz" -- "$BINARY" \
    >"$RESULTS/server.log" 2>&1 &
  LAUNCHER_PID=$!
  for _ in $(seq 1 100); do
    SERVER_PID=$(pgrep -P "$LAUNCHER_PID" -x slimm-server || true)
    [[ -n "$SERVER_PID" ]] && break
    sleep 0.1
  done
else
  "${PIN[@]}" "$BINARY" >"$RESULTS/server.log" 2>&1 &
  SERVER_PID=$!
  LAUNCHER_PID=$SERVER_PID
fi
[[ -n "$SERVER_PID" ]] || { echo "server did not start" >&2; exit 1; }

for _ in $(seq 1 150); do
  curl -fsS -m 1 "$BASE/healthz" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$RESULTS/server.log" >&2; exit 1; }
  sleep 0.2
done
curl -fsS -m 1 "$BASE/healthz" >/dev/null || { echo "server never became healthy" >&2; exit 1; }

LOAD_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')
export LOAD_ADMIN_PASSWORD
OWNER_TOKEN=$(python3 "$ROOT/scripts/lib/load_admin.py" claim "$BASE")

python3 "$ROOT/scripts/lib/load_resource.py" sample "$SERVER_PID" "$RESULTS/server-resources.csv" &
SAMPLER_PID=$!
python3 "$ROOT/scripts/lib/load_admin.py" metrics "$BASE" "$RESULTS/metrics-before.txt"

K6_NAME="slimm-load-k6-$$"
sample_k6() {
  local pid=""
  for _ in $(seq 1 100); do
    pid=$(docker inspect -f '{{.State.Pid}}' "$K6_NAME" 2>/dev/null || true)
    [[ -n "$pid" && "$pid" != 0 ]] && break
    sleep 0.1
  done
  [[ -z "$pid" ]] || python3 "$ROOT/scripts/lib/load_resource.py" sample "$pid" "$RESULTS/k6-resources.csv"
}
sample_k6 &
K6_SAMPLER_PID=$!
K6_STATUS=0
docker run --rm --name "$K6_NAME" --network host "${K6_PIN[@]}" --user "$(id -u):$(id -g)" --ulimit nofile=1048576:1048576 \
  -v "$ROOT/perf/load:/load:ro" -v "$RESULTS:/results" \
  -e BASE_URL="$BASE" -e OWNER_TOKEN="$OWNER_TOKEN" -e RESULTS_DIR=/results \
  "$K6_IMAGE" run --quiet "$@" "/load/$SCENARIO.js" 2>&1 | tee "$RESULTS/k6.log" || K6_STATUS=${PIPESTATUS[0]}

kill "$K6_SAMPLER_PID" 2>/dev/null || true
python3 "$ROOT/scripts/lib/load_admin.py" metrics "$BASE" "$RESULTS/metrics-after.txt" || true
kill "$SAMPLER_PID" 2>/dev/null || true
SAMPLER_PID=""
{
  echo "server during the run"
  python3 "$ROOT/scripts/lib/load_resource.py" summarize "$RESULTS/server-resources.csv" || true
  echo "k6 during the run (if this is near the cores it was given, the result is k6's limit)"
  python3 "$ROOT/scripts/lib/load_resource.py" summarize "$RESULTS/k6-resources.csv" || true
} | tee "$RESULTS/server-resources.txt"

stop_server
rm -rf "$WORK/data"

echo
echo "results   $RESULTS"
if [[ "$PROFILE" = 1 && -f "$RESULTS/profile.json.gz" ]]; then
  LOAD_START=$(sed -n 's/.*load-start \([0-9]*\).*/\1/p' "$RESULTS/k6.log" | head -1)
  python3 "$ROOT/scripts/lib/load_profile.py" "$RESULTS/profile.json.gz" 30 "${LOAD_START:-0}" >"$RESULTS/profile-top.txt" || true
  echo "top       $RESULTS/profile-top.txt   (samples from after seeding only)"
  echo "profile   samply load $RESULTS/profile.json.gz   (opens the Firefox Profiler)"
fi
exit "$K6_STATUS"
