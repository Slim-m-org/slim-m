<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0104 - A personal background picture, and panes that are half translucent over it

Status: accepted
Date: 2026-11-02
Touches the surface roles in [0004](0004-visual-identity-review.md): the three pane surfaces stop being fully opaque while a picture is set.

## The ask

A member asked how hard it would be to upload a picture for the background with a transparency filter on it.
Their example was a forest photo with a vignette, so it does not distract from the chat.
The owner wants it in the next release.

## Decision

- The picture is personal and per device.
  It lives in Settings > Appearance > Background, beside the theme, and is never uploaded.
  Natively it is one PNG under the application support directory (`appearance/background.png`).
  On web it is one record in IndexedDB, because localStorage is too small for a picture.
- It is shrunk on import so its longest side is at most 2560 and a source over 100 megapixels is refused before any pixel is allocated.
  It is decoded once, held as one `ui.Image`, and painted as one `RepaintBoundary` layer behind the shell.
  Dim, vignette and blur change only that layer, so the chat below is not rebuilt.
- The vignette and the dim both fade toward the theme's own base surface, never toward black.
  A light theme therefore lightens its edges and a dark one darkens them, and neither can pull text below its contrast.
- Only the pane roots take part: the channel rail, the conversation, the member roster, the call stage and the compact app bar.
  Their surfaces keep 50% of their own colour over the picture (`kBackgroundPaneAlpha`).
  The docked thread pane, the composer, menus, sheets, dialogs and the drawers on a phone stay opaque, and a drawer resets the scope with `OpaquePanes`.
- Text contrast is guaranteed, not eyeballed.
  `minimumBackgroundDim` finds the least fade at which primary and secondary text reach 4.5:1 on both pane surfaces over the darkest and lightest pixel of the picture.
  The picture's range is read once at import from a 48 pixel area-averaged thumbnail, and falls back to pure black and white when it is unknown.
  The dim slider cannot go below that floor, and the painted pixels are measured against it in `app_background_contrast_test.dart` for all seven themes.
  With an unknown picture the floors are light 0.79, soft 0.74, mocha 0.69, dark 0.64, forest 0.63, halloween 0.58 and true black 0.46.
- High contrast, in the app or on the platform, turns the picture off and puts every pane back to opaque.
  Settings says so instead of hiding the card.
- One layout serves every width.
  The picker is `showAppSheet` (rule 3 of `docs/design/desktop-vs-mobile.md`, and law 1: width decides, never platform), a sheet on touch and a menu on a pointer.

## Cost

Semi-opaque panes are the first surfaces whose contrast depends on content the app did not choose.
The worst-case floor keeps that safe, at the price that a very bright picture in a light theme can only show faintly.
