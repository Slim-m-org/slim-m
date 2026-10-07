#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# The one-line comment cap from CLAUDE.md: a plain `//` or `#` comment never
# spans more than one line. Code explains how; a comment explains why, and one
# line is enough for a why. A reason that genuinely needs more room belongs in
# a doc comment on the item, in docs/, or in a decision record.
#
# Doc comments are exempt (`///`, `//!`, `/**`): they carry an item's contract
# to its callers and to `dart doc` / `cargo doc`, which is a different job.
#
# Scope is Dart, Rust, Python, shell, YAML (inline workflow `run:` blocks
# included) and TOML. Shell, YAML and TOML only have `#` comments, and a `#`
# block is also how such a file documents itself, so the leading block at the
# top of the file (shebang, SPDX line, description, blank lines between them)
# is a file header and is never a run. Any run after the first line of real
# content counts like it does everywhere else.
#
# Ratcheting, not a big-bang sweep: runs that predate this gate are held in
# scripts/comment-cap-allow.txt at each file's count when it was listed, and
# this fails if a file exceeds its own number. Fixing a file lowers its entry;
# a file not listed must be clean.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
allowfile=scripts/comment-cap-allow.txt

declare -A ceiling=()
declare -A seen=()
if [[ -f $allowfile ]]; then
  while IFS= read -r line; do
    line=${line%%#*}
    read -r path max _ <<<"$line" || true
    [[ -n ${path:-} ]] || continue
    if ! [[ ${max:-} =~ ^[0-9]+$ ]]; then
      echo "::error file=$allowfile::'$path' has no run count; the format is '<path> <runs> # why'" >&2
      exit 1
    fi
    ceiling[$path]=$max
  done <"$allowfile"
fi

# Counts maximal runs of 2+ plain-comment lines, including /* */ blocks that open their own line (not /** or /*!); nested blocks are not modelled.
runs_in() {
  local file="$1" hash_only=0
  case $file in
    *.sh | *.yml | *.yaml | *.toml) hash_only=1 ;;
    *) ;;
  esac
  awk -v hash_only="$hash_only" -v header="$hash_only" '
    # The top-of-file block of a #-only file is its header, not a run.
    header && (/^[[:space:]]*$/ || /^[[:space:]]*#/) { next }
    { header = 0 }
    # A plain comment is // not followed by / or !, or # not followed by !; shell and YAML have no // or /*.
    !hash_only && (/^[[:space:]]*\/\/[^\/!]/ || /^[[:space:]]*\/\/$/) { streak++; next }
    /^[[:space:]]*#([^!]|$)/ { streak++; next }
    in_block {
      block_lines++
      if ($0 ~ /\*\//) { if (block_lines > 1) runs++; in_block = 0; block_lines = 0 }
      if (streak > 1) runs++
      streak = 0
      next
    }
    !hash_only && (/^[[:space:]]*\/\*[^*!]/ || /^[[:space:]]*\/\*$/) {
      if (streak > 1) runs++
      streak = 0
      if ($0 ~ /\*\//) next
      in_block = 1
      block_lines = 1
      next
    }
    { if (streak > 1) runs++; streak = 0 }
    END {
      if (streak > 1) runs++
      if (in_block && block_lines > 1) runs++
      print runs + 0
    }
  ' "$file"
}

status=0
checked=0
over=0

while IFS= read -r file; do
  case $file in
    *.g.dart | *.freezed.dart | .sqlx/* | */generated/*) continue ;;
    *) ;;
  esac
  checked=$((checked + 1))
  count=$(runs_in "$file")
  allowed=${ceiling[$file]:-0}
  seen[$file]=1
  if ((count > allowed)); then
    over=$((over + 1))
    status=1
    if ((allowed > 0)); then
      echo "::error file=$file::$count multi-line comment runs, over its recorded $allowed; compress the new one or move the why to a doc comment" >&2
    else
      echo "::error file=$file::$count multi-line comment run(s); a plain comment is capped at one line (a doc comment is not)" >&2
    fi
  elif ((count < allowed)); then
    over=$((over + 1))
    status=1
    if ((count > 0)); then
      echo "::error file=$allowfile::$file is down to $count multi-line comment runs; lower the entry from $allowed to $count" >&2
    else
      echo "::error file=$allowfile::$file has no multi-line comment runs left; drop the line" >&2
    fi
  fi
done < <(git ls-files '*.dart' '*.rs' '*.py' '*.sh' '*.yml' '*.yaml' '*.toml')

# A stale allowlist entry (deleted or renamed file) is only a warning.
for path in "${!ceiling[@]}"; do
  [[ -n ${seen[$path]:-} ]] || echo "::warning file=$allowfile::'$path' is listed but no longer exists; drop the line"
done

echo "comment cap: $checked files checked, $over over their ceiling, ${#ceiling[@]} allowlisted"
exit $status
