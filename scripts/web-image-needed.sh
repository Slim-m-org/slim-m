#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The web image twin of server-image-needed.sh: asks what the live web image was built from, not what this push touched.
set -euo pipefail

current_sha="${1:?usage: web-image-needed.sh <current-sha>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$here/image-needed.sh" web "web-image / merge" "$current_sha" \
  client/ 'docker/web*' .github/workflows/web-image.yml .github/actions/
