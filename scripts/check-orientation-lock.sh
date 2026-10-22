#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#
# Orientation is locked to portrait on phones only. The iOS app is iPhone
# only (device family 1, no iPad orientation array), so the Android
# sw600dp override is the one place a tablet is freed, and the two halves
# fail in opposite directions if either is quietly edited: landscape back
# in the iPhone array stretches the phone-sized shell across a 932pt-wide
# window that the layout classes as a two-pane tablet, and dropping
# landscape from the sw600dp override freezes an Android tablet in
# portrait. Neither shows up in a diff as a behaviour change.
#
# Lifted verbatim out of hygiene.yml so local hooks and CI run the same code.
# -e alone, matching the `bash -e {0}` GitHub runs a `run:` block with.
set -e

plist=client/packages/app/ios/Runner/Info.plist
res=client/packages/app/android/app/src/main/res
fail=0

phone=$(awk '/<key>UISupportedInterfaceOrientations<\/key>/{f=1}
             f{print}
             f&&/<\/array>/{exit}' "$plist")
pbx=client/packages/app/ios/Runner.xcodeproj/project.pbxproj

if [ -z "$phone" ]; then
  echo "::error::$plist is missing an orientation array"
  fail=1
fi
# Landscape in the array is only the ceiling for full screen call video (decision 0058).
if grep -q 'Landscape' <<<"$phone"; then
  swift=client/packages/app/ios/Runner/AppDelegate.swift
  scode=$(sed -e 's://.*::' "$swift" |
          awk '/\/\*/{c=1} !c{print} /\*\//{c=0}')
  for token in 'supportedInterfaceOrientationsFor' \
               'static var landscapeAllowed = false' \
               'landscapeAllowed ? .allButUpsideDown : .portrait'; do
    grep -qF "$token" <<<"$scode" || {
      echo "::error::$plist allows landscape but $swift no longer keeps the shell portrait ($token is gone)"
      fail=1
    }
  done
  callers=$(grep -rlE 'allowLandscape\(true\)' client/packages/app/lib |
            xargs -r grep -lE '^[^/]*allowLandscape\(true\)' || true)
  if [ "$callers" != "client/packages/app/lib/src/providers/phone_landscape.dart" ]; then
    echo "::error::only phone_landscape.dart may ask for landscape; found: ${callers:-none}"
    fail=1
  fi
  holders=$(grep -rlE '^[^/]*PhoneLandscapeHold\(' client/packages/app/lib |
            grep -v 'providers/phone_landscape.dart' | sort | tr '\n' ' ' || true)
  if [ "$holders" != "client/packages/app/lib/src/features/canvas/screens/canvas_pane.dart client/packages/app/lib/src/features/voice/widgets/fullscreen_video_overlay.dart " ]; then
    echo "::error::only fullscreen video and a fullscreen canvas tile may hold landscape; found: ${holders:-none}"
    fail=1
  fi
fi
if grep -q 'UISupportedInterfaceOrientations~ipad' "$plist"; then
  echo "::error::$plist declares iPad orientations; the app is iPhone only"
  fail=1
fi
if grep 'TARGETED_DEVICE_FAMILY' "$pbx" | grep -qv '= 1;'; then
  echo "::error::$pbx has a build configuration that is not iPhone only"
  fail=1
fi

grep -q '<bool name="slimm_portrait_only">true</bool>' \
  "$res/values/bools.xml" || {
  echo "::error::$res/values/bools.xml must lock phones to portrait"
  fail=1
}
grep -q '<bool name="slimm_portrait_only">false</bool>' \
  "$res/values-sw600dp/bools.xml" || {
  echo "::error::$res/values-sw600dp/bools.xml must free tablets"
  fail=1
}

# Both resources can stay exactly as they are while the only code that reads them is deleted, which is a silent unlock.
kt=client/packages/app/android/app/src/main/kotlin/top/npcserver/slimm/MainActivity.kt
code=$(sed -e 's://.*::' "$kt" |
       awk '/\/\*/{c=1} !c{print} /\*\//{c=0}')
for token in 'override fun onCreate' \
             'R.bool.slimm_portrait_only' \
             'requestedOrientation' \
             'SCREEN_ORIENTATION_PORTRAIT'; do
  grep -qF "$token" <<<"$code" || {
    echo "::error::$kt no longer applies the lock ($token is gone)"
    fail=1
  }
done

manifest=client/packages/app/web/manifest.json
if grep -qF '"orientation"' "$manifest"; then
  echo "::error::$manifest sets an orientation; an installed web app cannot tell a phone from a desktop, so it would lock every desktop install too"
  fail=1
fi

if [ $fail -eq 0 ]; then
  echo "orientation locked on phones only"
fi
exit $fail
