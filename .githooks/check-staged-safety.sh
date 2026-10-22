#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Rejects staged files that look like credentials or that are large binaries, before they reach history.
# SLIMM_ALLOW_LARGE=1 lets a deliberate large asset through; there is no bypass for credentials except --no-verify.
set -uo pipefail

limit=$((1024 * 1024))
status=0

name_pattern='(^|/)(\.env|\.env\.[a-z]+|id_rsa|id_ed25519|.*\.pem|.*\.p12|.*\.pfx|.*\.keystore|.*\.jks|.*\.mobileprovision|slimm-data\.key|discord\.json)$'
allowed_names='(^|/)\.env\.example$'
secret_pattern='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}'

while IFS= read -r f; do
  if [[ $f =~ $name_pattern ]] && ! [[ $f =~ $allowed_names ]]; then
    echo "::error file=$f::looks like a credentials file; do not commit it"
    status=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACM)

added=$(git diff --cached --diff-filter=ACM -U0 --no-color | grep -E '^(\+\+\+ b/|\+[^+])' || true)
if grep -Eq -e "$secret_pattern" <<<"$added"; then
  echo "::error::a staged line looks like a private key or API token"
  awk -v pat="$secret_pattern" '/^\+\+\+ b\// {file=substr($0, 7)} $0 ~ pat && !/^\+\+\+ / {print "  in: " file}' <<<"$added" | sort -u
  status=1
fi

if [ "${SLIMM_ALLOW_LARGE:-0}" != 1 ]; then
  while IFS=$'\t' read -r added _ f; do
    [ "$added" = "-" ] || continue
    size=$(git cat-file -s ":$f" 2>/dev/null || echo 0)
    if [ "$size" -gt "$limit" ]; then
      echo "::error file=$f::binary file of $((size / 1024)) KiB staged; the limit is $((limit / 1024)) KiB"
      status=1
    fi
  done < <(git diff --cached --numstat --diff-filter=AM)
fi
exit $status
