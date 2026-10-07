#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Prints the RPM Release for a COPR snapshot of a commit, without the dist tag:
#   <N>.<UTC commit time as YYYYMMDDHHMMSS>git<7-char sha>
# where N is the integer Release in the spec (the release workflow's own).
#
# rpm compares Release segment by segment, a number above letters, so this
# sorts above <N>%{?dist} (the release it follows) and below <N+1>, and below
# any later version outright. Snapshots order by commit time, not by which
# workflow built them, so a catch-up run can never outrank a newer commit.
#
# Usage: copr-snapshot-release.sh <spec> [rev]   (run inside the checkout)
set -euo pipefail

spec="${1:?usage: copr-snapshot-release.sh <spec> [rev]}"
rev="${2:-HEAD}"

base="$(sed -n 's/^Release:[[:space:]]*\([0-9][0-9]*\)\([^0-9].*\)\{0,1\}$/\1/p' "$spec" | head -n1)"
if [ -z "$base" ]; then
  echo "no integer Release: line in ${spec}" >&2
  exit 1
fi

# The submit job runs in a container whose checkout belongs to another user, and git refuses to read such a repo unless told it is trusted.
trusted() { git -c "safe.directory=$PWD" "$@"; }

stamp="$(TZ=UTC trusted log -1 --format=%cd --date=format-local:%Y%m%d%H%M%S "$rev")"
sha="$(trusted rev-parse --short=7 "$rev")"
printf '%s.%sgit%s\n' "$base" "$stamp" "$sha"
