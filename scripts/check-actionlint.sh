#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# actionlint over every workflow, which also shellchecks the inline `run:` blocks.
# Pinned by image digest so a local run and CI disagree about nothing.
set -e

docker run --rm -v "$PWD":/repo -w /repo \
  rhysd/actionlint@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9 \
  -color
