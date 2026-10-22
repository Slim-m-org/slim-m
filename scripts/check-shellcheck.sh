#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Lints every tracked shell script with shellcheck, at the digest the runner uses.
# The runner's preinstalled shellcheck and the `stable` image are different versions that disagree, so neither is trusted.
set -euo pipefail

mapfile -t scripts < <({ git ls-files '*.sh'; git grep -lE '^#!(/usr/bin/env )?(/bin/)?(ba)?sh$' -- ':(exclude)*.sh'; } | sort -u)
printf 'checking %d scripts\n' "${#scripts[@]}"
docker run --rm -v "$PWD":/repo -w /repo \
  koalaman/shellcheck@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d \
  "${scripts[@]}"
