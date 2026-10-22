#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# App Store review rejects a missing purpose string asynchronously, by
# email after CI is green. This makes it a red PR; see docs/ci.md.
#
# Lifted verbatim out of hygiene.yml so local hooks and CI run the same code.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

plist=client/packages/app/ios/Runner/Info.plist
missing=()
# NSLocationWhenInUseUsageDescription is here for an API the app never calls: ITMS-90683 rejected build 82 over a linked SDK's Core Location reference, and dropping the key repeats that.
for key in NSCameraUsageDescription NSMicrophoneUsageDescription \
           NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription \
           NSLocationWhenInUseUsageDescription \
           NSLocalNetworkUsageDescription \
           NSFaceIDUsageDescription; do
  grep -q "<key>$key</key>" "$plist" || missing+=("$key")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "::error::$plist is missing purpose strings: ${missing[*]}."
  echo "App Store review will reject the upload after CI goes green."
  exit 1
fi
echo "ios purpose strings present"
