#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Screen share on iOS is a second process. Every piece below is read at
# runtime and every one of them fails silently when it is wrong: the
# button does nothing, or the broadcast starts and sends no frames.
# That is exactly how this shipped broken, so the gate checks the
# identifiers agree rather than merely that each file exists.
#
# Lifted verbatim out of hygiene.yml so local hooks and CI run the same code.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

ios=client/packages/app/ios
pbx=$ios/Runner.xcodeproj/project.pbxproj
ext=$ios/BroadcastExtension
fail=0

value() {
  awk -v k="$1" '$0 ~ "<key>"k"</key>" {
    getline
    gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, "")
    print
    exit
  }' "$2"
}
group_in() {
  awk '/<key>com.apple.security.application-groups<\/key>/ {f=1; next}
       f && /<string>/ {
         gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, "")
         print
         exit
       }' "$1"
}

# The Xcode target itself. Without the appex embedded in the app there is nothing for the system picker to offer.
grep -q 'productType = "com.apple.product-type.app-extension";' \
  "$pbx" || {
  echo "::error::$pbx has no app-extension target"
  fail=1
}
# Membership has to be read out of the build phases themselves. Every one of these strings also appears in the file's own PBXBuildFile declaration, which survives being dropped from the target, so grepping the whole file passes over the break it is looking for.
section() {
  awk -v s="$1" '$0 ~ "Begin "s" section" {f=1}
                 f {print}
                 $0 ~ "End "s" section" {f=0}' "$pbx"
}
copy_phases=$(section PBXCopyFilesBuildPhase)
sources=$(section PBXSourcesBuildPhase)

grep -q 'BroadcastExtension.appex in Embed Foundation Extensions' \
  <<<"$copy_phases" || {
  echo "::error::$pbx does not embed BroadcastExtension.appex"
  fail=1
}
grep -q 'dstSubfolderSpec = 13;' <<<"$copy_phases" || {
  echo "::error::$pbx has no PlugIns copy phase for the extension"
  fail=1
}

# A source file present on disk but absent from the target compiles nowhere and is invisible in a diff.
for f in "$ext"/*.swift; do
  grep -q "$(basename "$f") in Sources" <<<"$sources" || {
    echo "::error::$(basename "$f") is not in any target's Sources"
    fail=1
  }
done

point=$(value NSExtensionPointIdentifier "$ext/Info.plist")
[ "$point" = "com.apple.broadcast-services-upload" ] || {
  echo "::error::$ext/Info.plist is not a broadcast upload extension"
  fail=1
}
grep -q 'RPBroadcastProcessModeSampleBuffer' "$ext/Info.plist" || {
  echo "::error::$ext/Info.plist must use the sample buffer mode"
  fail=1
}

# livekit_client reads this key to pick the extension; a value that names no real bundle shows an empty picker.
ext_id=$(value RTCScreenSharingExtension "$ios/Runner/Info.plist")
[ -n "$ext_id" ] || {
  echo "::error::Runner/Info.plist has no RTCScreenSharingExtension"
  fail=1
}
if [ -n "$ext_id" ]; then
  count=$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = $ext_id;" "$pbx")
  [ "$count" -ge 3 ] || {
    echo "::error::$pbx does not build $ext_id in all three configs"
    fail=1
  }
fi

# The App Group is the only channel between the two processes, and all four of these have to be the same string.
group=$(value RTCAppGroupIdentifier "$ios/Runner/Info.plist")
[ -n "$group" ] || {
  echo "::error::Runner/Info.plist has no RTCAppGroupIdentifier"
  fail=1
}
if [ -n "$group" ]; then
  app_group=$(group_in "$ios/Runner/Runner.entitlements")
  ext_group=$(group_in "$ext/BroadcastExtension.entitlements")
  [ "$app_group" = "$group" ] || {
    echo "::error::Runner.entitlements grants '$app_group', not '$group'"
    fail=1
  }
  [ "$ext_group" = "$group" ] || {
    echo "::error::the extension grants '$ext_group', not '$group'"
    fail=1
  }
  grep -q "\"$group\"" "$ext/BroadcastConstants.swift" || {
    echo "::error::BroadcastConstants.swift does not use '$group'"
    fail=1
  }
fi

# Manual signing needs a profile per embedded bundle, or the export fails late, on the release runner, naming this id.
if [ -n "$ext_id" ]; then
  grep -q "<key>$ext_id</key>" "$ios/ExportOptions.plist" || {
    echo "::error::ExportOptions.plist has no profile for $ext_id"
    fail=1
  }
  # The name too, not just the key: xcodebuild matches it literally.
  grep -q "slim-m Broadcast Extension App Store" "$ios/ExportOptions.plist" || {
    echo "::error::ExportOptions.plist does not name the extension's profile"
    fail=1
  }
fi

if [ $fail -eq 0 ]; then
  echo "ios broadcast extension wired: $ext_id in $group"
fi
exit $fail
