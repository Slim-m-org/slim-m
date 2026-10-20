#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Boot (or stop) the whole slim-m deployment both end-to-end suites drive.
#
# Nothing here is mocked: a real LiveKit SFU, the real server binary, the real
# web build of the client, a seeded server with two accounts and a voice
# channel, and the speech-shaped WAV the browsers capture as a microphone.
# Shared by scripts/e2e.sh (the Python harness) and e2e/ (Playwright Test), so
# the two suites test the same thing.
#
# Usage: scripts/e2e-stack.sh up|down|restart-server
#   up    start the stack and write $E2E_WORK/stack.json and stack.env
#   down  stop what `up` started, found through the pid files it wrote
#   restart-server  kill and relaunch the server on the same database
#
# Environment (defaults in brackets):
#   E2E_WORK [e2e/.work]   work dir: database, logs, pid files, stack.json
#   E2E_API_PORT [8095]   the server
#   E2E_WEB_PORT [8356]   the static web build
#   E2E_LK_PORT [7880]    LiveKit's HTTP/WebSocket port on the host
#   E2E_RTC_TCP_PORT [7881]  LiveKit's ICE TCP port, so a second stack can run beside the first
#   E2E_WEB_DIR           serve this prebuilt web bundle instead of the tree's own
#   E2E_REBUILD           set to rebuild the web client even if one exists
#   E2E_PASSWORD          pin the seeded accounts' password (default: random)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${E2E_WORK:-$ROOT/e2e/.work}"
WEB_PORT="${E2E_WEB_PORT:-8356}"
API_PORT="${E2E_API_PORT:-8095}"
LK_PORT="${E2E_LK_PORT:-7880}"
LK_CONTAINER="${E2E_LK_CONTAINER:-slimm-e2e-lk}"
# The version prod runs, so the run tests what ships rather than whatever is latest.
LIVEKIT_VERSION="${LIVEKIT_VERSION:-v1.10.1}"
# Below the kernel's ephemeral range (32768-60999), where an outgoing socket can already hold a port.
RTC_UDP_START="${E2E_RTC_UDP_START:-21000}"
RTC_UDP_END="${E2E_RTC_UDP_END:-21050}"
RTC_TCP_PORT="${E2E_RTC_TCP_PORT:-7881}"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
PIDS="$WORK/pids"
# LiveKit's dev-mode key pair for a throwaway container; overridable.
export LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-devkey}"
export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-secret}"

# What was actually built, since a stale tree passes and reads as thorough.
say_commit() {
  local head behind
  head="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "e2e: building from $head"
  git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null || return 0
  behind="$(git -C "$ROOT" rev-list --count "HEAD..origin/main" 2>/dev/null || echo 0)"
  [[ "$behind" == "0" ]] || echo "e2e: WARNING this tree is $behind commit(s) behind origin/main"
  git -C "$ROOT" diff --quiet 2>/dev/null || echo "e2e: note the working tree has uncommitted changes"
}

need() {
  local tool="$1"
  command -v "$tool" >/dev/null || { echo "missing: $tool"; exit 1; }
}

stop_pid_file() {
  local file="$PIDS/$1.pid" pid
  [[ -f "$file" ]] || return 0
  pid="$(cat "$file")"
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  rm -f "$file"
}

down() {
  stop_pid_file web
  stop_pid_file api
  docker rm -f "$LK_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK/slimm.db"* "$WORK/stack.json" "$WORK/stack.env"
}

wait_for_url() {
  local url="$1" tries="$2"
  for _ in $(seq "$tries"); do
    curl -sf -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

start_sfu() {
  echo "== SFU =="
  docker rm -f "$LK_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$LK_CONTAINER" --rm \
    -p "$LK_PORT:7880" -p "$RTC_TCP_PORT:$RTC_TCP_PORT" -p "$RTC_UDP_START-$RTC_UDP_END:$RTC_UDP_START-$RTC_UDP_END/udp" \
    -e LIVEKIT_CONFIG="rtc: {port_range_start: $RTC_UDP_START, port_range_end: $RTC_UDP_END, tcp_port: $RTC_TCP_PORT}" \
    "livekit/livekit-server:$LIVEKIT_VERSION" --dev --bind 0.0.0.0 >/dev/null
  wait_for_url "http://localhost:$LK_PORT" 30 || true
}

start_server() {
  echo "== server =="
  ( cd "$ROOT" && SQLX_OFFLINE=true cargo build --release --bin slimm-server -q )
  # A server already on this port answers with a build this run did not compile.
  if curl -sf -o /dev/null "http://localhost:$API_PORT/healthz" 2>/dev/null; then
    echo "port $API_PORT is already serving something; stop that first"; exit 1
  fi
  SLIMM_PORT=$API_PORT \
  SLIMM_DATABASE_PATH="$WORK/slimm.db" \
  SLIMM_CORS_ALLOWED_ORIGINS="http://localhost:$WEB_PORT" \
  SLIMM_LIVEKIT_URL="ws://localhost:$LK_PORT" \
  SLIMM_LIVEKIT_API_KEY=$LIVEKIT_API_KEY \
  SLIMM_LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET \
    setsid "$TARGET_DIR/release/slimm-server" > "$WORK/server.log" 2>&1 < /dev/null &
  echo $! > "$PIDS/api.pid"
  for _ in $(seq 60); do
    [[ "$(curl -s "http://localhost:$API_PORT/healthz" 2>/dev/null)" == "ok" ]] && return 0
    sleep 1
  done
  echo "server never came up:"; tail -20 "$WORK/server.log"; exit 1
}

serve_web() {
  echo "== web build =="
  local tree_web="$ROOT/client/packages/app/build/web"
  local web_dir="${E2E_WEB_DIR:-$tree_web}"
  # The two gitignored binaries drift needs at runtime; absent, no local database.
  bash "$ROOT/client/packages/app/tool/fetch_web_assets.sh"
  if [[ "$web_dir" != "$tree_web" ]]; then
    # A prebuilt bundle is the caller's: never deleted, never rebuilt over.
    if [[ ! -f "$web_dir/main.dart.js" ]]; then
      echo "E2E_WEB_DIR=$web_dir has no main.dart.js; point it at a built web bundle"; exit 1
    fi
  elif [[ ! -f "$web_dir/main.dart.js" || -n "${E2E_REBUILD:-}" ]]; then
    # Flutter copies web/ into build/web once and never re-syncs a new file into it.
    rm -rf "$web_dir"
    # Bundled canvaskit: the default fetches it from gstatic, which failed once on a runner and left a blank page.
    ( cd "$ROOT/client/packages/app" && flutter build web --release --no-web-resources-cdn )
  fi
  if [[ "$web_dir" != "$tree_web" && -n "${E2E_REBUILD:-}" ]]; then
    echo "E2E_REBUILD is ignored: E2E_WEB_DIR is a prebuilt bundle and is never rebuilt"
  fi
  echo "web bundle: $web_dir ($(tr -d '\n ' < "$web_dir/version.json" 2>/dev/null || echo 'no version.json'))"
  if curl -sf -o /dev/null "http://localhost:$WEB_PORT/" 2>/dev/null; then
    echo "port $WEB_PORT is already serving something; stop that first"; exit 1
  fi
  setsid python3 -m http.server "$WEB_PORT" --directory "$web_dir" >/dev/null 2>&1 < /dev/null &
  echo $! > "$PIDS/web.pid"
  # Every file the app reaches for at runtime, not just the ones a build emits.
  for asset in main.dart.js flutter_bootstrap.js sqlite3.wasm drift_worker.js; do
    wait_for_url "http://localhost:$WEB_PORT/$asset" 20 || {
      echo "the web build does not serve $asset."
      echo "see client/packages/app/web/README.md; the channel rail and sync both"
      echo "fail with nothing but 'Could not load channels.' when it is missing."
      exit 1; }
  done
}

write_stack_files() {
  python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
env = os.environ
stack = {
    "api": f"http://localhost:{env['API_PORT']}",
    "web": f"http://localhost:{env['WEB_PORT']}",
    "voiceRoom": env["VOICE_ROOM"],
    "voiceChannelName": env["VOICE_CHANNEL_NAME"],
    "secret": env["VOICE_SECRET"],
    "wav": f"{work}/fake-voice.wav",
    "fixtures": f"{work}/fixtures",
    "livekit": {
        "http": f"http://localhost:{env['LK_PORT']}",
        "key": env["LIVEKIT_API_KEY"],
        "secret": env["LIVEKIT_API_SECRET"],
    },
}
with open(f"{work}/stack.json", "w", encoding="utf-8") as fh:
    json.dump(stack, fh, indent=2)
    fh.write("\n")
PY
  {
    echo "VOICE_ROOM=\"$VOICE_ROOM\""
    echo "VOICE_SECRET=\"$VOICE_SECRET\""
    echo "VOICE_WAV=\"$WORK/fake-voice.wav\""
  } > "$WORK/stack.env"
}

teardown_if_failed() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    echo "== stack failed, tearing down =="
    down
  fi
}

up() {
  need docker; need flutter; need cargo; need python3; need curl
  say_commit
  trap teardown_if_failed EXIT
  mkdir -p "$WORK" "$PIDS" "$WORK/fixtures"
  # A stale stack left by a crashed run would hold the ports.
  down
  mkdir -p "$PIDS"
  python3 "$ROOT/scripts/lib/e2e_fixtures.py" "$WORK/fixtures"

  start_sfu
  start_server

  echo "== accounts and a voice channel =="
  eval "$(python3 "$ROOT/scripts/lib/e2e_seed.py" "http://localhost:$API_PORT")"
  echo "  voice channel $VOICE_CHANNEL_NAME ($VOICE_ROOM)"

  serve_web

  # Chrome's fake tone is too quiet for LiveKit to call speech, so capture scripts/lib/make_fake_voice.py's WAV instead.
  python3 "$ROOT/scripts/lib/make_fake_voice.py" "$WORK/fake-voice.wav"

  export API_PORT WEB_PORT LK_PORT VOICE_ROOM VOICE_CHANNEL_NAME VOICE_SECRET
  write_stack_files
  echo "stack up: web :$WEB_PORT, api :$API_PORT, sfu :$LK_PORT ($WORK/stack.json)"
}

# Kills and relaunches only the server, keeping its database: what a deploy does to connected clients.
restart_server() {
  stop_pid_file api
  for _ in $(seq 20); do
    curl -sf -o /dev/null "http://localhost:$API_PORT/healthz" 2>/dev/null || break
    sleep 0.5
  done
  start_server
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  restart-server) restart_server ;;
  *) echo "usage: $0 up|down|restart-server" >&2; exit 2 ;;
esac
