#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Runs the COPR snapshot Release tests against real rpm, in the image the COPR jobs use.
# rpmdev-vercmp is not packaged for Ubuntu, so the hygiene runner would otherwise skip them and never compare the Python port with rpm.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
docker run --rm \
  -e PYTHONDONTWRITEBYTECODE=1 -e SLIMM_REQUIRE_TEST_DEPS=rpmdev-vercmp \
  -v "$PWD":/repo:ro -w /repo/scripts/lib \
  fedora:44@sha256:15da97ed9aa94dd3d92c3925eb89520f6c80e07ea7ee24cba848d1f8b6912b3e \
  bash -c 'dnf -y -q install git python3 rpmdevtools >/dev/null && python3 -m unittest -v test_copr_snapshot_release_sorts_above_the_release test_required_test_dependencies_are_present'
