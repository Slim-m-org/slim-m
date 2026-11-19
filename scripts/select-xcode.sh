#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Points xcode-select at one installed Xcode, or fails naming the ones the runner image has.
# Usage: select-xcode.sh <xcode version> <lowest iOS SDK major App Store Connect accepts>
set -euo pipefail

version=$1
min_sdk=$2
apps=${XCODE_APPS_DIR:-/Applications}
app="$apps/Xcode_$version.app"

if [[ ! -d $app ]]; then
  echo "::error::Xcode $version is not on this runner image (${ImageOS:-unknown} ${ImageVersion:-unknown}); pin one it has in .github/actions/select-xcode/action.yml"
  ls -d "$apps"/Xcode_*.app 2>/dev/null || echo "this image has no Xcode under $apps"
  exit 1
fi

sudo xcode-select --switch "$app/Contents/Developer"
xcodebuild -version
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
if [[ ${sdk%%.*} -lt $min_sdk ]]; then
  echo "::error::Xcode $version ships the iOS $sdk SDK; App Store Connect wants iOS $min_sdk or later (ITMS-90725)"
  exit 1
fi
echo "building with Xcode $version and the iOS $sdk SDK"
