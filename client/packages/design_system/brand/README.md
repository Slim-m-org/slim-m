# Brand marks

The slim-m mark and every icon generated from it.
The SVGs here are the source of truth; every PNG in the repo is a build product of one of them, so change a master and re-run `generate.sh` rather than editing a bitmap.

## The mark

"Off-grid": three dots of a lattice, and one object that has left it.
The shape difference is the whole idea, which is why the dots and the square are never coloured separately.

Authoritative geometry, on a 32 viewBox, all solid, no stroke:

```svg
<circle cx="9"  cy="9"  r="3.2"/>
<circle cx="21" cy="9"  r="3.2"/>
<circle cx="9"  cy="21" r="3.2"/>
<rect x="15" y="15" width="11" height="11" rx="3.5"/>
```

The dot radius is 3.2 rather than 3, bought deliberately to keep the lattice from thinning at 16px.
Do not clean that number up.

Two derived constants the masters depend on, both worth keeping if the geometry ever moves.
The mark's bounding box runs 5.8 to 26 on both axes, so it is 20.2 units square, centred on (15.9, 15.9).
Its furthest ink from that centre is 12.958 units, at the top-left dot, which is what decides whether it clears Android's safe circle.

## Rules

- Primary treatment is `accentFill` on `surfaceBase`. That is the app icon, the favicon, and the mark in the client.
- One colour throughout. Never recolour the dots separately from the square.
- Clear space is one dot diameter, 6.4 units at the 32 grid, on every side.
- Minimum size is 16px. Below that use `glyph.svg`, the square alone.
- Never rotate it, gradient it, put it in a circle, or recolour it.

## Colour

The masters hard-code the dark theme's `accentFill` `#58B4D8` on `surfaceBase` `#17191C`.
Both are read from [`../lib/src/app_tokens.dart`](../lib/src/app_tokens.dart), which is the only place they are decided.
An icon cannot follow a runtime theme, so the dark tile is used in both, and Android gets no `-night` colour variant for the same reason.

If the accent ever moves again, edit the five hard-coded fills here plus `values/ic_launcher_background.xml`, then regenerate.
Anything claiming the accent is `#4FBDB4` is stale: that is the pre-0.4.0 teal.

## Files

| Master | Feeds |
|---|---|
| `mark.svg` | the mark alone, `currentColor`, for docs and in-client use |
| `glyph.svg` | the below-16px fallback, square alone, `currentColor` |
| `icon-master.svg` | 512 tile, 114 radius, mark at 60%; web, Android legacy, Linux, macOS, Windows |
| `icon-ios.svg` | as above but square and opaque; iOS, and the web touch icon |
| `icon-maskable.svg` | smaller mark, full bleed; the maskable web icons |
| `android-foreground.svg` | 108dp adaptive foreground, transparent |
| `android-monochrome.svg` | 108dp themed-icon layer, flat white |

`mark.svg` and `glyph.svg` inherit their colour, so rasterising either one directly gives black.
That is intended: they are templates, and the icons that need a fixed colour have their own master.

`glyph.svg` is scaled for equal ink weight with the full mark rather than an equal bounding box, so swapping one for the other does not change how heavy the icon looks.

## Regenerating

```bash
client/packages/design_system/brand/generate.sh
```

It needs ImageMagick 7 (`magick`) built against librsvg, which is what Fedora ships.
The script asserts every output's dimensions and fails loudly rather than writing a wrong-sized icon.

Outputs, none of which should be edited by hand:

- `client/packages/app/ios/Runner/Assets.xcassets/AppIcon.appiconset/`, the 15 sizes `Contents.json` names
- `client/packages/app/android/app/src/main/res/mipmap-*/`, the legacy launcher icon plus the adaptive foreground and monochrome layers
- `client/packages/app/web/`, `favicon.png`, the four manifest icons, and the Apple touch icon
- `packaging/linux/icons/`, the hicolor ladder the rpm installs
- `client/packages/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/`, the tile on Apple's 824-in-1024 grid with a transparent margin
- `client/packages/app/windows/runner/resources/app_icon.ico`, seven sizes from 16 to 256, edge to edge

Two things the script works around, both of which fail quietly rather than loudly.
ImageMagick renders an SVG at its natural size and upscales from there unless `-density` drives it, which costs a visibly soft edge, so the script renders natively at `96*px/units` for every target.
An iOS app icon carrying an alpha channel is rejected by App Store validation asynchronously, after CI is green, so those 15 are flattened to PNG24 and the channel is removed explicitly.

## Platform notes

iOS gets a square, full-bleed tile because it applies its own superellipse mask.
The spec's 114/512 radius describes that mask rather than something the asset should bake in; pre-rounding it would show a gap inside the system corner.

Android's adaptive icon masks the outer 18dp of a 108dp canvas away and only guarantees a 66dp circle.
The foreground mark is 60% of the 72dp visible area, matching the iOS and web tiles optically, and its circumscribed circle lands at 55.4dp.
The background layer is a flat colour resource rather than a bitmap, because it is one.
`mipmap-anydpi-v26/ic_launcher.xml` takes over from API 26; the `ic_launcher.png` bitmaps stay for the levels below it.

The maskable web icons carry more padding than the plain ones, since a maskable icon is cropped to an arbitrary shape and only its centre 80% survives.
The Apple touch icon is opaque because iOS composites a home-screen icon onto black instead of honouring alpha.
