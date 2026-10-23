<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0089 - Soft dark and Forest are the fifth and sixth app themes

Status: accepted
Date: 2026-10-22
Extends [0004](0004-visual-identity-review.md) and [0088](0088-catppuccin-mocha-theme.md).

## The ask

A dimmer grey dark, easier on the eyes than Dark and clearly lighter than True black.
And one theme with real character, unlike anything already shipped.

## Decision

- `AppTokens.soft`, picked as "Soft dark": the same cool slate neutrals and glacier accent as Dark, lifted to a mid-grey ramp (`#22262B`, `#2B3036`, `#363C44`).
  It keeps the product accent, so it needs no exception to 0004.
- `AppTokens.forest`, picked as "Forest": deep pine surfaces (`#0B1411`, `#12201B`, `#1C2E27`) with a seafoam accent `#5FD4C4`.
  Like Catppuccin in 0088, the accent is the theme's own identity, which is an exception to the single product accent in 0004.
  The accent is still confined to the same closed set of roles.
- `AppThemeChoice.softDark` and `AppThemeChoice.forest` go at the end of the enum, so stored values from older builds stay valid.
- Both map to `ThemeMode.dark` as palettes of the dark slot; `system` still resolves to plain Dark.
- The theme choice stays space-scoped under 0070.
- The picker lays out four cards across at and above `kCompactWidth` and two below it.

## Why Forest

Midnight indigo with amber and synthwave were rendered next to it.
Midnight reads as a sibling of Catppuccin (blue-violet surfaces), and synthwave sits in the same purple family.
Forest is the only candidate whose surfaces leave both slate and violet, and it passes every gate.

## Alternates

| Token | Midnight | Synthwave |
|---|---|---|
| surfaceSunken, Base, Raised | `#0A0C1F`, `#12152E`, `#1D2145` | `#0F0820`, `#1A0F33`, `#2A1A4D` |
| borderStrong | `#7B80B3` | `#8F77C4` |
| textPrimary, Secondary | `#E8E9F7`, `#A9ADD4` | `#F4EEFF`, `#BDAEE0` |
| accent, accentOn | `#F2B35A`, `#1A1204` | `#FF5FA8`, `#1A0610` |
| accentSoft | `#3A3050` | `#4A1F4A` |
| dangerText, warnText | `#F08C86`, `#E9C46A` | `#FF8A80`, `#FFD166` |
