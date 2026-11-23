#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Fetches the two binaries the web build needs, pinned to the versions in
# pubspec.lock and checked against a recorded digest, and copies the capture
# chain worklet out of the pinned flutter_webrtc fork.
#
# They are fetched rather than committed because the web build is a test
# surface rather than something shipped, so 355KB of vendored minified JS in
# git bought nothing and cost a linter finding on every line of it.
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK=../../pubspec.lock
WEB=web

# Digests are the contract: a mismatched worker fails at runtime in the browser, not at build.
SQLITE3_VERSION=3.6.0
SQLITE3_SHA=13d3f11d05b39ba0618a7115fb41640a5d48b6300f5d3f325f554b42bd6688a4
DRIFT_VERSION=2.35.0
DRIFT_SHA=df0066e75363a9bed59a14eedbbded421c1f5910f8379812df164716aa2e6eed

pinned() {
  local name=$1
  awk -v pkg="  $name:" '$0 == pkg {found=1} found && /version:/ {gsub(/[" ]/, "", $2); print $2; exit}' "$LOCK"
}

# Refuse on a lockfile mismatch: a digest pinned against another version is worse than no check.
check_pinned() {
  local pkg=$1 want=$2 actual
  actual=$(pinned "$pkg")
  if [[ "$actual" != "$want" ]]; then
    echo "error: pubspec.lock pins $pkg $actual but this script expects $want." >&2
    echo "Update the version and sha256 in $0 in the same change." >&2
    exit 1
  fi
}

check_pinned sqlite3 "$SQLITE3_VERSION"
check_pinned drift "$DRIFT_VERSION"

fetch() {
  local url=$1 out=$2 want=$3
  if [[ -f "$out" && "$(sha256sum "$out" | cut -d' ' -f1)" == "$want" ]]; then
    echo "ok $out (cached)"
    return
  fi
  # Retries cover the transient release-CDN 503 that killed three e2e runs on 2026-08-12 (#621).
  curl -sSfL --max-time 120 --retry 5 --retry-delay 5 --retry-all-errors \
    "$url" -o "$out"
  local got
  got=$(sha256sum "$out" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    rm -f "$out"
    echo "error: $out digest mismatch. expected $want, got $got" >&2
    exit 1
  fi
  echo "ok $out"
}

mkdir -p "$WEB"
fetch "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_VERSION}/sqlite3.wasm" \
  "$WEB/sqlite3.wasm" "$SQLITE3_SHA"
fetch "https://github.com/simolus3/drift/releases/download/drift-${DRIFT_VERSION}/drift_worker.js" \
  "$WEB/drift_worker.js" "$DRIFT_SHA"

# The browser's capture chain (docs/voice-input-gate.md) is built in the fork and pinned with it, so it needs a resolved workspace.
CONFIG=../../.dart_tool/package_config.json
if [[ ! -f "$CONFIG" ]]; then
  echo "error: $CONFIG is missing; run flutter pub get in client/ first." >&2
  exit 1
fi
FORK=$(awk '/"name": "flutter_webrtc"/ {found=1} found && /"rootUri"/ {gsub(/.*"rootUri": "(file:\/\/)?|\/?",?$/, ""); print; exit}' "$CONFIG")
# A path dependency is written relative to the config's own folder.
[[ "$FORK" == /* ]] || FORK="$(dirname "$CONFIG")/$FORK"
for file in capture_chain.wasm capture_chain_worklet.js; do
  if [[ ! -f "$FORK/web_capture_chain/$file" ]]; then
    echo "error: the pinned flutter_webrtc ($FORK) has no web_capture_chain/$file." >&2
    exit 1
  fi
  cp "$FORK/web_capture_chain/$file" "$WEB/$file"
  echo "ok $WEB/$file"
done
