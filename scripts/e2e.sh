#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Stand up a whole slim-m deployment and drive two clients through the product,
# then tear it all down.
#
# Nothing here is mocked: a real LiveKit SFU, the real server binary, the real
# web build of the client, and two isolated browsers that join the same channel
# and publish microphones to each other. Two isolated profiles matter because
# this box runs several agent sessions at once and a shared Chrome profile picks
# up another session's state, which reads exactly like an app bug.
#
# Usage: scripts/e2e.sh [--keep]
#   --keep  leave the stack running afterwards for poking at by hand
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export E2E_WORK="${E2E_WORK:-/tmp/e2e}"
WORK="$E2E_WORK"
SHOTS="$WORK/shots"
export E2E_WEB_PORT="${E2E_WEB_PORT:-8356}"
export E2E_API_PORT="${E2E_API_PORT:-8095}"
WEB_PORT=$E2E_WEB_PORT
API_PORT=$E2E_API_PORT
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

export E2E_SHOTS="$SHOTS"
export E2E_FIXTURES="$WORK/fixtures"
export E2E_SCHEMA="$ROOT/schema/openapi.yaml"
# LiveKit's dev-mode key pair for a throwaway container; overridable.
export LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-devkey}"
export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-secret}"

cleanup() {
  local code=$?
  if [[ $KEEP -eq 1 ]]; then
    echo "--keep: stack left up (web :$WEB_PORT, api :$API_PORT, sfu :${E2E_LK_PORT:-7880})"
    return
  fi
  echo "== teardown =="
  pkill -f "remote-debugging-port=980[12]" 2>/dev/null || true
  bash "$ROOT/scripts/e2e-stack.sh" down
  rm -rf "$WORK/chrome-alice" "$WORK/chrome-bob"
  exit $code
}
trap cleanup EXIT

CHROME="$(command -v google-chrome-stable || command -v google-chrome || true)"
[[ -n "$CHROME" ]] || { echo "missing: google-chrome-stable"; exit 1; }
python3 -c "import websocket" 2>/dev/null || {
  echo "missing python package: pip install --user websocket-client"; exit 1; }

mkdir -p "$WORK" "$SHOTS"
bash "$ROOT/scripts/e2e-stack.sh" up
# shellcheck source=/dev/null
source "$WORK/stack.env"

echo "== two browsers =="
for pair in "9801:alice" "9802:bob"; do
  port="${pair%%:*}"; who="${pair##*:}"
  profile="$WORK/chrome-$who"; rm -rf "$profile"; mkdir -p "$profile"
  # Detached headless Chrome dies with the launching shell, so each is held open by a sleep it outlives.
  nohup setsid bash -c "exec '$CHROME' --headless=new \
    --user-data-dir='$profile' --remote-debugging-port=$port \
    --window-size=1280,900 --no-first-run --no-default-browser-check \
    --use-fake-device-for-media-stream --use-fake-ui-for-media-stream \
    --use-file-for-fake-audio-capture='$VOICE_WAV' \
    --autoplay-policy=no-user-gesture-required --enable-unsafe-swiftshader \
    --mute-audio \
    --auto-select-desktop-capture-source='Entire screen' \
    'http://localhost:$WEB_PORT'" > "$WORK/chrome-$who.log" 2>&1 < /dev/null &
done
for port in 9801 9802; do
  for _ in $(seq 40); do
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null 2>&1 && break
    sleep 1
  done
done
sleep 6

echo "== drive =="
python3 -u "$ROOT/scripts/lib/e2e_run.py" \
  "http://localhost:$API_PORT" "$VOICE_ROOM" "$VOICE_SECRET"
echo "screenshots in $SHOTS"
