#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Rasterises the SVG masters in this directory into every icon the repo ships.
# Run it after changing a master or an accent token; see README.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../../../.." && pwd)"
app="${root}/client/packages/app"

command -v magick >/dev/null || { echo "magick (ImageMagick 7) is required" >&2; exit 1; }

# ImageMagick renders an SVG at its natural size and upscales from there unless
# density drives it, which costs a blurry edge. 96*px/units renders natively.
# Pass mode "opaque" for a flattened PNG24, which is what iOS demands.
render() {
  local src="$1" units="$2" px="$3" out="$4" mode="${5:-alpha}"
  local density got
  density="$(awk -v p="${px}" -v u="${units}" 'BEGIN{printf "%.6f", 96*p/u}')"
  mkdir -p "$(dirname "${out}")"
  if [[ "${mode}" = "opaque" ]]; then
    magick -density "${density}" "${here}/${src}" -strip \
      -background "#17191C" -alpha remove -alpha off PNG24:"${out}"
  else
    magick -background none -density "${density}" "${here}/${src}" -strip png32:"${out}"
  fi
  got="$(magick identify -format '%wx%h' "${out}")"
  [[ "${got}" = "${px}x${px}" ]] || { echo "${out}: rendered ${got}, wanted ${px}x${px}" >&2; exit 1; }
}

echo "ios"
ios="${app}/ios/Runner/Assets.xcassets/AppIcon.appiconset"
# Sizes are the ones AppIcon.appiconset/Contents.json actually names.
while read -r px name; do
  render icon-ios.svg 512 "${px}" "${ios}/${name}" opaque
done <<'EOF'
20 Icon-App-20x20@1x.png
40 Icon-App-20x20@2x.png
60 Icon-App-20x20@3x.png
29 Icon-App-29x29@1x.png
58 Icon-App-29x29@2x.png
87 Icon-App-29x29@3x.png
40 Icon-App-40x40@1x.png
80 Icon-App-40x40@2x.png
120 Icon-App-40x40@3x.png
120 Icon-App-60x60@2x.png
180 Icon-App-60x60@3x.png
76 Icon-App-76x76@1x.png
152 Icon-App-76x76@2x.png
167 Icon-App-83.5x83.5@2x.png
1024 Icon-App-1024x1024@1x.png
EOF

echo "android"
res="${app}/android/app/src/main/res"
# Legacy launcher icon, for the API levels below 26 that cannot mask an
# adaptive one. The adaptive layers below take over from 26 up.
while read -r px bucket; do
  render icon-master.svg 512 "${px}" "${res}/mipmap-${bucket}/ic_launcher.png"
done <<'EOF'
48 mdpi
72 hdpi
96 xhdpi
144 xxhdpi
192 xxxhdpi
EOF

# Adaptive layers are 108dp against the same density ladder. The background
# layer is a flat colour resource, so it needs no bitmap.
while read -r px bucket; do
  render android-foreground.svg 108 "${px}" "${res}/mipmap-${bucket}/ic_launcher_foreground.png"
  render android-monochrome.svg 108 "${px}" "${res}/mipmap-${bucket}/ic_launcher_monochrome.png"
done <<'EOF'
108 mdpi
162 hdpi
216 xhdpi
324 xxhdpi
432 xxxhdpi
EOF

echo "web"
web="${app}/web"
render icon-master.svg 512 32 "${web}/favicon.png"
render icon-master.svg 512 192 "${web}/icons/Icon-192.png"
render icon-master.svg 512 512 "${web}/icons/Icon-512.png"
render icon-maskable.svg 512 192 "${web}/icons/Icon-maskable-192.png"
render icon-maskable.svg 512 512 "${web}/icons/Icon-maskable-512.png"
# iOS composites a home-screen icon onto black rather than honouring its alpha,
# so the touch icon is the square opaque master, not the rounded tile.
render icon-ios.svg 512 180 "${web}/icons/Icon-apple-touch-180.png" opaque

echo "linux packaging"
# The hicolor ladder the rpm installs. Suffixed by size because rpm flattens
# every Source into one directory, so the basenames have to differ there.
pkg="${root}/packaging/linux/icons"
# Under a 32px tile the full mark falls below its own 16px floor (it is 62% of
# the tile, so 24px draws it at 14.9), and the dots turn to noise. See glyph.svg.
for px in 16 22 24; do
  render icon-master-small.svg 512 "${px}" "${pkg}/top.npcserver.slimm-${px}.png"
done
for px in 32 48 64 128 256 512; do
  render icon-master.svg 512 "${px}" "${pkg}/top.npcserver.slimm-${px}.png"
done
# Shipped as scalable/apps, which covers every HiDPI scale of the sizes above.
cp "${here}/icon-master.svg" "${pkg}/top.npcserver.slimm.svg"

echo "macos"
mac="${app}/macos/Runner/Assets.xcassets/AppIcon.appiconset"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
# macOS applies no mask: the tile sits on Apple's 824-in-1024 grid, the rest transparent.
for px in 16 32 64 128 256 512 1024; do
  body=$(( px * 824 / 1024 ))
  src=icon-master.svg
  (( body < 32 )) && src=icon-master-small.svg
  render "${src}" 512 "${body}" "${scratch}/mac-${px}.png"
  magick "${scratch}/mac-${px}.png" -background none -gravity center \
    -extent "${px}x${px}" png32:"${mac}/app_icon_${px}.png"
done

echo "windows"
# Windows draws an icon edge to edge, so the tile fills each size the .ico carries.
ico=()
for px in 16 24 32 48 64 128 256; do
  src=icon-master.svg
  (( px < 32 )) && src=icon-master-small.svg
  render "${src}" 512 "${px}" "${scratch}/win-${px}.png"
  ico+=("${scratch}/win-${px}.png")
done
magick "${ico[@]}" "${app}/windows/runner/resources/app_icon.ico"

echo "done"
