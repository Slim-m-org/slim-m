<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0120 - Theme gallery: themes as live miniatures inside Settings

Status: accepted
Date: 2026-11-16
Extends [0106](0106-space-theme-store.md).

## Decision

The owner chose the Gallery proposal, with grafts from Compact and Live preview.

## Themes

Themes is now a sub-page of the Appearance pane, so the settings nav, the title position and the close X stay put, and on a phone it takes the pane's app bar.
SettingsPanes gained sub-pages for this, and /settings/themes redirects to /settings?pane=appearance&page=themes.
Each theme is a card with a live miniature of the app in its own colours: three across beside the nav, two on a phone, built lazily with a repaint boundary per card.
One tap applies a theme from any source, and the card in use is marked wherever it came from.
The custom theme slot now keeps a source id (builtin, mine, space or file) beside it, so a Space theme shows as in use and an unsaved one says Not saved.
The Space default appears once: as a tag on its card, with Follow Space default as a switch on Appearance.
Built-in themes get a pencil for Customise instead of a menu with one item, and System has neither.
Right-click, long-press and the kebab open the same menu, and every phone sheet names the theme it acts on.
Delete and Remove now ask first.
A Space theme that cannot be applied says why on its card.

## Appearance

Appearance now opens with a live preview of the theme in use, where it came from, its main action, up to five recent themes and Browse themes.
With a pointer, hovering a recent theme previews it and a click applies it.
The controls on the right of Appearance share one 280 px column, and slider values carry their unit.

## The editor

The editor opens inside the pane, with the draft preview pinned above one column and a Save footer pinned below that says why Save is off.
Accent, Background, Text and Warning text carry linked colours that follow them until changed, and the links belong to the editor session, not the theme file.
The colour picker checks contrast while dragging.

## Scope

No server, API or theme file change; the new device-local keys are the custom theme source, Recent and where the background came from.
Not built: Undo after applying, the light and dark filter, and moving Clock and the member toggles.
