#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Regenerates client/packages/app/android/gradle/verification-metadata.xml,
# the checksum of every artifact the Android build resolves. Run it after a
# Flutter upgrade, a plugin bump that changes Android dependencies, or any
# edit under android/; the android-ci workflow fails until the file matches.
#
# The real google-services.json is a CI secret, and the google-services
# plugin only applies when that file exists, so the committed placeholder
# stands in to make this resolve the same graph a release build does.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/client/packages/app"
json="$app/android/app/google-services.json"
placeholder="$app/android/app/google-services.placeholder.json"

# An empty Gradle home, so every parent POM and BOM is read the way a fresh CI runner reads it; a warm cache skips them.
fresh_home="$(mktemp -d "${TMPDIR:-/tmp}/gradle-home.XXXXXX")"
export GRADLE_USER_HOME="${VERIFY_GRADLE_USER_HOME:-$fresh_home}"

copied=0
if [[ ! -f "$json" ]]; then
  cp "$placeholder" "$json"
  copied=1
fi
cleanup() {
  if [[ $copied -eq 1 ]]; then rm -f "$json"; fi
  # The daemon keeps writing into its Gradle home, so it stops before that home is removed.
  (cd "$app/android" && ./gradlew --stop >/dev/null 2>&1) || true
  rm -rf "$fresh_home"
}
trap cleanup EXIT

cd "$app"
flutter pub get --enforce-lockfile
# Writes local.properties and the generated plugin settings gradlew needs.
flutter build apk --release --config-only
cd android
rm -f gradle/verification-metadata.xml
./gradlew --write-verification-metadata sha256 \
  assembleRelease bundleRelease assembleDebug assembleProfile
echo "wrote $app/android/gradle/verification-metadata.xml"
