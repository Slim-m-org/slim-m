#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The file-size budget from CLAUDE.md: 300 lines soft, 500 lines hard.
# Warns at 300; past 500 (or an allowlisted ceiling) it warns within $slack lines
# and fails beyond, so a file a few lines over gets a split card, not a split mid-feature.
# Files already past 500 are in scripts/file-budget-allow.txt at their own ceiling.
# What is excluded and why, and why 300 does not fail, is in docs/ci.md.
# schema/openapi.yaml is exempt outright: it is the wire contract, guarded by the
# router contract test and the additive-only oasdiff gate, and no split helps it.

set -euo pipefail

soft=300
hard=500
slack=60

cd "$(git rev-parse --show-toplevel)"
allowfile=scripts/file-budget-allow.txt

declare -A ceiling=()
declare -A hit=()
while IFS= read -r line; do
  line=${line%%#*}
  read -r path max _ <<<"$line" || true
  [[ -n ${path:-} ]] || continue
  if ! [[ ${max:-} =~ ^[0-9]+$ ]]; then
    echo "::error file=$allowfile::'$path' has no line-count ceiling; the format is '<path> <lines> # why'" >&2
    exit 1
  fi
  ceiling["$path"]=$max
done <"$allowfile"

mapfile -t files < <(
  git ls-files -- \
    '*.rs' '*.dart' '*.py' '*.sh' '*.swift' '*.kt' '*.kts' '*.js' \
    '*.sql' '*.yml' '*.yaml' '*.toml' '*.cc' '*.h' '*.gradle' |
    grep -v '^node_modules/' |
    grep -v '^\.sqlx/' |
    grep -Fxv 'schema/openapi.yaml' |
    grep -Ev '\.(g|freezed|pb|pbenum|pbjson|pbserver)\.dart$' |
    sort
)

fail=0
soft_count=0
hard_count=0

for f in "${files[@]}"; do
  n=$(wc -l <"$f")
  limit=${ceiling[$f]:-}
  if [[ -n $limit ]]; then
    hit["$f"]=$n
    if [[ $n -gt $((limit + slack)) ]]; then
      echo "::error file=$f::$n lines, more than $slack past the $limit it was allowlisted at; split it" >&2
      fail=1
    elif [[ $n -gt $limit ]]; then
      echo "::warning file=$f::$n lines, past the $limit it was allowlisted at; file a Planka card to split it"
    fi
    continue
  fi
  if [[ $n -gt $((hard + slack)) ]]; then
    echo "::error file=$f::$n lines, more than $slack over the ${hard}-line limit; split it in this change" >&2
    hard_count=$((hard_count + 1))
    fail=1
  elif [[ $n -gt $hard ]]; then
    echo "::warning file=$f::$n lines, over the ${hard}-line limit; file a Planka card to split it"
    hard_count=$((hard_count + 1))
  elif [[ $n -gt $soft ]]; then
    echo "::warning file=$f::$n lines, over the ${soft}-line review budget; split it before it grows again"
    soft_count=$((soft_count + 1))
  fi
done

for f in "${!ceiling[@]}"; do
  n=${hit[$f]:-}
  if [[ -z $n ]]; then
    echo "::error file=$allowfile::$f is allowlisted but is not a checked source file any more; remove the entry" >&2
    fail=1
  elif [[ $n -le $hard ]]; then
    echo "::error file=$allowfile::$f is down to $n lines and no longer needs an entry; remove it" >&2
    fail=1
  fi
done

echo "file budget: ${#files[@]} files checked, $soft_count over $soft, $hard_count over $hard, ${#ceiling[@]} allowlisted"
exit $fail
