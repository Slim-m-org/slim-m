<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0101 - Halloween is an app theme, and a theme can carry a procedural backdrop

Status: accepted
Date: 2026-11-01
Extends [0089](0089-soft-dark-and-forest-themes.md).

## The ask

A seasonal theme, and "anything fancy like textures/images in the theme".
The theme picker had also grown to a wall of big cards, so it became a compact dropdown with a small colour swatch per theme.

## Decision

- `AppTokens.halloween`, picked as "Halloween": violet-black surfaces (`#110B16`, `#1A1221`, `#251A2E`), warm off-white text `#F4EADB` and a pumpkin accent `#FF7A1A`.
  Like Catppuccin and Forest, the accent is the theme's own identity, within the same closed set of roles.
- Status and code colours are slime green, candle yellow and blood red variants that pass the existing contrast gates unchanged.
- `AppThemeChoice.halloween` goes at the end of the enum and maps to `ThemeMode.dark`.
- `AppTokens.backdrop` is an optional `AppBackdrop`, null for every other theme.
  `ThemeBackdrop` in the design system paints it above the routed tree from `appChromeBuilder`, and renders nothing when the theme has none.
- The only backdrop is `halloweenWebs`: cobwebs anchored in two corners plus a few specks, drawn by a `CustomPainter` at roughly 7 to 9 percent alpha.
  It is static, wrapped in `IgnorePointer`, `ExcludeSemantics` and `RepaintBoundary`, and ships no image asset.
- The picker is one `SettingsSelectRow` with a three-colour swatch (surface, accent, text) beside the current value and each choice.
