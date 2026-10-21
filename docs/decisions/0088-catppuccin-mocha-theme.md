<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0088 - Catppuccin Mocha is the fourth app theme

Status: accepted
Date: 2026-10-21
Extends [0004](0004-visual-identity-review.md).

## The ask

A fourth app colour theme that people already know and like.
Catppuccin Mocha won the research over Dracula because its palette is documented, MIT-licensed and has enough steps to build the three-surface ramp.

## Decision

- The theme is `AppTokens.mocha`, picked as "Catppuccin" in Settings, Appearance.
- The accent is mauve `#cba6f7`, the theme's own identity, rather than the product's cyan.
  Links follow the accent, as in the other themes.
- `AppThemeChoice.catppuccin` goes at the end of the enum, so stored values from older builds stay valid.
- `system` still resolves to the plain dark theme.
  The new theme is a choice, never something an operating system setting selects.
- The theme maps to `ThemeMode.dark` and is the dark theme built from a different token set, like true black.
- Canvas inks, cursors and embed accents are unchanged, so a board looks the same for everyone.

## Mapping

Every pair below is gated by the same contrast, ramp, boundary and focus tests as the other themes.

| Token | Catppuccin colour |
|---|---|
| surfaceSunken, surfaceBase, surfaceRaised | crust, base, surface0 |
| borderSubtle, borderStrong | surface1, overlay1 |
| textPrimary, textSecondary, textDisabled | text, subtext0, overlay0 |
| accent, accentFill, focusRing | mauve |
| accentOn | crust |
| accentSoft | `#38324c`, mauve at 15 percent over base |
| status online, away, dnd, offline | green, yellow, red, overlay0 |
| dangerText, dangerBorder, warnText | red, maroon, yellow |
| code keyword, string, number, comment, punctuation | mauve, green, peach, subtext0, subtext0 |

## Traps found while choosing

- Mantle, base, surface0 fails `surface_ramp_test`: the rails step is too small next to the raised step.
  Crust, base, surface0 passes.
- Overlay0 as `borderStrong` is under 3:1 on the raised surface, so overlay1 is used.
- Overlay1 and overlay2 as code comments fail 4.5:1 on the raised surface, so subtext0 is used.

## Licence

The palette is catppuccin/palette v1.8.0 under the MIT licence.
The notice and copyright line are in `LICENSES/Catppuccin-MIT.txt`.

## Layout of the picker

Five cards sit across at and above `kCompactWidth` and go two by two below it, with the last card keeping a column's width.
Width decides, not platform: the one rule in `docs/design/desktop-vs-mobile.md`.
