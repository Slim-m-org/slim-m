# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# shellcheck shell=bash
# Shared helpers for the pre-commit and pre-push hooks; sourced, never run.

if [ -n "${SLIMM_HOOK_ENV:-}" ] && [ -f "$SLIMM_HOOK_ENV" ]; then
  # shellcheck disable=SC1090
  . "$SLIMM_HOOK_ENV"
fi

# A linked worktree runs hooks from its own top level, so this is the checkout being committed or pushed.
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 1

export SQLX_OFFLINE="${SQLX_OFFLINE:-true}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
export TMPDIR="${TMPDIR:-/tmp}"
export FLUTTER_CONCURRENCY="${SLIMM_HOOK_FLUTTER_CONCURRENCY:-2}"

HOOK_LOG_DIR=$(mktemp -d "$TMPDIR/slimm-hook.XXXXXX")
trap 'rm -rf "$HOOK_LOG_DIR"' EXIT

NAMES=()
RESULTS=()
TIMES=()
FAILED=0

have() { command -v "$1" >/dev/null 2>&1; }

# Runs a named check quietly and records its summary row; later checks are "not run" after a failure unless SLIMM_HOOK_KEEP_GOING=1.
step() {
  local name=$1
  shift
  if [ -n "${SLIMM_HOOK_SKIP:-}" ] && grep -Eq -e "$SLIMM_HOOK_SKIP" <<<"$name"; then
    skip "$name" "SLIMM_HOOK_SKIP"
    return 0
  fi
  if [ "$FAILED" -ne 0 ] && [ "${SLIMM_HOOK_KEEP_GOING:-0}" != 1 ]; then
    record "$name" "not run" 0
    return 0
  fi
  local log="$HOOK_LOG_DIR/$((${#NAMES[@]})).log" start end
  printf '  ... %s\n' "$name" >&2
  start=${EPOCHREALTIME/./}
  if "$@" >"$log" 2>&1; then
    end=${EPOCHREALTIME/./}
    record "$name" "pass" $(((end - start) / 1000))
  else
    end=${EPOCHREALTIME/./}
    record "$name" "FAIL" $(((end - start) / 1000))
    FAILED=1
    printf '\n----- %s failed -----\n' "$name" >&2
    tail -n 60 "$log" >&2
    # A test failure scrolls out of the tail on a long suite, so the failing names always print last.
    grep -aE '\[E\]$|^\s+FAIL \[|^(FAIL|ERROR): ' "$log" | sort -u | tail -n 20 >&2 || true
    [ -n "${FIX:-}" ] && printf 'fix: %s\n' "$FIX" >&2
    printf -- '---------------------\n\n' >&2
  fi
  FIX=
}

skip() { record "$1" "skip ($2)" 0; }

record() {
  NAMES+=("$1")
  RESULTS+=("$2")
  TIMES+=("$3")
}

fmt_ms() { printf '%d.%01d' $(($1 / 1000)) $((($1 % 1000) / 100)); }

summary() {
  local i total=0
  printf '\n%-52s %-22s %6s\n' "check" "result" "secs" >&2
  printf '%-52s %-22s %6s\n' "-----" "------" "----" >&2
  for i in "${!NAMES[@]}"; do
    printf '%-52s %-22s %6s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "$(fmt_ms "${TIMES[$i]}")" >&2
    total=$((total + TIMES[i]))
  done
  printf '%-52s %-22s %6s\n' "total" "" "$(fmt_ms "$total")" >&2
  if [ "$FAILED" -ne 0 ]; then
    printf '\n%s blocked. Fix the failure above, or bypass once with --no-verify.\n' "$HOOK_NAME" >&2
    return 1
  fi
  return 0
}

matches() { # matches <regex> <file-list-var-name>
  local -n list=$2
  printf '%s\n' "${list[@]}" | grep -Eq "$1"
}

pick() { # pick <regex>: lines of CHANGED matching the regex
  printf '%s\n' "${CHANGED[@]}" | grep -E "$1" || true
}
