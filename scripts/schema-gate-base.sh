#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Usage: schema-gate-base.sh
# Prints the revision the push-time schema gate diffs HEAD against, run from a checkout that has its tags.
# A server release commit is checked against the newest schema-v* tag before it, so one breaking change cannot ride in on an earlier commit; any other commit against its parent.
set -euo pipefail

subject="$(git log -1 --format=%s HEAD)"
if [[ "$subject" == "chore(main): release server "* ]]; then
  if ! tag="$(git describe --tags --abbrev=0 --match 'schema-v*' HEAD~1)"; then
    echo "::error::no schema-v* tag is reachable from the parent of this release commit; this gate cannot pass without one" >&2
    exit 1
  fi
  echo "$tag"
else
  echo "HEAD~1"
fi
