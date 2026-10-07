#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Measures idle and peak RSS of the slimm-server release binary on both
# libcs that matter: the host's glibc, and the musl build every release
# actually ships, via the committed docker/server.Dockerfile.
#
# Assumptions this script does not verify for you:
#   - a release binary already exists (build it with
#     `SQLX_OFFLINE=true cargo build --locked --release --bin slimm-server`)
#   - docker is installed and usable, unless --skip-musl is passed
#   - ports 18099 and 18100 are free on this host (override with --port-glibc
#     / --port-musl if another agent session is already using them)
#   - nothing else on this machine is under heavy load while it runs: RSS is
#     sensitive to what else is competing for pages, not only this process
#
# Exits non-zero when a requested measurement did not produce numbers.
#
# Usage: perf/measure-idle-rss.sh [--bin PATH] [--image TAG]
#                                  [--skip-glibc] [--skip-musl]
#                                  [--port-glibc PORT] [--port-musl PORT]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/.." && pwd)"

bin_path="${repo_root}/target/release/slimm-server"
image_tag=""
skip_glibc=0
skip_musl=0
port_glibc=18099
port_musl=18100

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) bin_path="$2"; shift 2 ;;
    --image) image_tag="$2"; shift 2 ;;
    --skip-glibc) skip_glibc=1; shift ;;
    --skip-musl) skip_musl=1; shift ;;
    --port-glibc) port_glibc="$2"; shift 2 ;;
    --port-musl) port_musl="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Populated by measure_glibc / measure_musl for the summary printed at the end.
idle_rss_glibc=""
peak_rss_glibc=""
idle_rss_musl=""
peak_rss_musl=""

wait_for_health() {
  local url="$1" code
  for _ in $(seq 1 "${SLIMM_RSS_HEALTH_ATTEMPTS:-30}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo 000)"
    [[ "${code}" == "200" ]] && return 0
    sleep 0.5
  done
  echo "timed out waiting for ${url} to answer healthy" >&2
  return 1
}

# Two readings a beat apart, so a still-warming process is not mistaken for steady state.
read_stable_rss() {
  local pid="$1" first second
  first="$(awk '/^VmRSS/ {print $2}' "/proc/${pid}/status")"
  sleep 2
  second="$(awk '/^VmRSS/ {print $2}' "/proc/${pid}/status")"
  if [[ "${first}" != "${second}" ]]; then
    echo "note: VmRSS still moving (${first} kB -> ${second} kB); using the later reading" >&2
  fi
  echo "${second}"
}

read_hwm() {
  local pid="$1"
  awk '/^VmHWM/ {print $2}' "/proc/${pid}/status"
}

measure_glibc() {
  if [[ ! -x "${bin_path}" ]]; then
    echo "no release binary at ${bin_path}; build it first (see perf/README.md)" >&2
    return 1
  fi
  echo "== glibc: ${bin_path} =="
  file "${bin_path}" | sed 's/^/  /'

  local db pid
  db="$(mktemp -u /tmp/slimm-rss-probe-XXXXXX.db)"
  SLIMM_PORT="${port_glibc}" SLIMM_DATABASE_PATH="${db}" "${bin_path}" &
  pid=$!
  trap 'kill "'"${pid}"'" 2>/dev/null || true; rm -f "'"${db}"'" "'"${db}"'-wal" "'"${db}"'-shm"' RETURN

  wait_for_health "http://localhost:${port_glibc}/healthz" || return 1
  idle_rss_glibc="$(read_stable_rss "${pid}")"
  peak_rss_glibc="$(read_hwm "${pid}")"
  echo "  idle_rss_glibc = ${idle_rss_glibc} kB"
  echo "  peak_rss_glibc = ${peak_rss_glibc} kB"
}

measure_musl() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found; skipping the musl measurement (pass --skip-musl to silence this)" >&2
    return 1
  fi
  local image="${image_tag}"
  if [[ -z "${image}" ]]; then
    image="slimm-server:rss-probe"
    echo "== building ${image} from docker/server.Dockerfile =="
    docker build -f "${repo_root}/docker/server.Dockerfile" -t "${image}" "${repo_root}" >/dev/null
  fi
  echo "== musl: ${image} (via docker/server.Dockerfile) =="

  local name="slimm-rss-probe-$$" host_pid
  docker run -d --name "${name}" -p "${port_musl}:8080" "${image}" >/dev/null
  trap 'docker rm -f "'"${name}"'" >/dev/null 2>&1 || true' RETURN

  wait_for_health "http://localhost:${port_musl}/healthz" || return 1
  host_pid="$(docker inspect --format '{{.State.Pid}}' "${name}")"
  idle_rss_musl="$(read_stable_rss "${host_pid}")"
  peak_rss_musl="$(read_hwm "${host_pid}")"
  echo "  idle_rss_musl = ${idle_rss_musl} kB"
  echo "  peak_rss_musl = ${peak_rss_musl} kB"
}

failed=0
if [[ "${skip_glibc}" -eq 0 ]]; then measure_glibc || failed=1; fi
if [[ "${skip_musl}" -eq 0 ]]; then measure_musl || failed=1; fi

echo
echo "== metrics entries, ready to paste into perf/baselines/<version>.json =="
for pair in "idle_rss_glibc:${idle_rss_glibc}" "peak_rss_glibc:${peak_rss_glibc}" \
            "idle_rss_musl:${idle_rss_musl}" "peak_rss_musl:${peak_rss_musl}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [[ -n "${value}" ]]; then
    printf '{ "name": "%s", "value": %s, "unit": "kB" }\n' "${name}" "${value}"
  fi
done

exit "${failed}"
