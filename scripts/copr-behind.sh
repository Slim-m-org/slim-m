#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Answers one question for copr-catch-up.yml: does COPR (nc1107/slim-m) lack a
# live build of slim-m-client at or above the version in client/pubspec.yaml?
#
# "Live" is any build that has not failed or been canceled, so a build that is
# still pending or running counts and a catch-up cannot double-submit behind
# main-builds. Only the Version part is compared, never the Release segment: a
# tagged 0.87.0-1 and a snapshot 0.87.0-1.20261006000000gitabcdef0 are the same version here, and
# RPM ordering between them is copr-publish.yml's concern, not this gate's.
#
# COPR_BUILDS_JSON points at a saved build list so scripts/lib/test_copr_behind.py
# needs no network; unset, the list is fetched from COPR's own API.
#
# Writes `behind=true|false` to $GITHUB_OUTPUT (or stdout when unset).

set -euo pipefail

: "${PUBSPEC_VERSION:?}"
api="https://copr.fedorainfracloud.org/api_3/build/list/?ownername=nc1107&projectname=slim-m&packagename=slim-m-client&limit=50&order=id&order_type=DESC"

if [ -n "${COPR_BUILDS_JSON:-}" ]; then
  builds="$(cat "$COPR_BUILDS_JSON")"
else
  builds="$(curl -fsS --retry 3 --retry-delay 5 "$api")"
fi

newest="$(jq -r '
  [.items[]
   | select(.state != "failed" and .state != "canceled")
   | .source_package.version // empty
   | split("-")[0]]
  | .[]' <<<"$builds" | sort -V | tail -n1)"

behind=true
if [ -n "$newest" ]; then
  top="$(printf '%s\n%s\n' "$newest" "$PUBSPEC_VERSION" | sort -V | tail -n1)"
  [ "$top" = "$newest" ] && behind=false
fi

echo "pubspec ${PUBSPEC_VERSION}, newest live COPR build ${newest:-none}, behind=${behind}" >&2
echo "behind=${behind}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
