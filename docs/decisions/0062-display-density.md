# 0062 - Message density, group spacing and interface scale

Status: accepted, 2026-10-08.

## The problem

The owner asked for "compaction settings like discord default / pixel slider to compact things" (2026-10-05).
The Appearance pane had a theme, a clock, motion and high contrast, and no way to make the interface denser or smaller.
`AppDensity` (compact, normal, spacious) already existed in the design system, but every call site pinned it to `normal`.

## Decision

Three per-device preferences in Appearance, stored like the theme and restored before the first frame.

- **Message density**: Compact, Default or Spacious, the existing `AppDensity` values.
  It sets the gap above a new group and above a continuation, from the enum's tokens, and the author avatar step: `AppAvatarSize.s28` at Compact, `s40` otherwise.
  The continuation gutter follows the avatar width, as before.
  Compact keeps the name and time on their own line; moving them inline is a separate layout change.
- **Group spacing**: extra space above a new group, in dp, added to the density's gap.
  The range is 0 to 16 in steps of 4, so every value is an `AppSpacing` step.
- **Interface scale**: 80 to 130 percent in steps of 5.
  Applied once at the app root, inside the desktop chrome, as a scaled layout: the routed tree is laid out at `size / scale` with `MediaQuery` size, padding and insets divided to match, then painted scaled.
  A text-scale-only approach was rejected because it leaves every fixed-size control and avatar unchanged, which is not what a "pixel slider" asks for.
  Width breakpoints read the effective width, so a large scale on a wide window can legitimately switch to the compact layout (desktop-vs-mobile rule: layout follows width, never platform).
  At 100 percent no wrapper is built.

## Constraints kept

- No new type sizes and no raw spacing: all gaps come from `AppDensity` and `AppSpacing`.
- Touch targets stay 44dp at touch density: the avatar's tap target keeps its finger-sized hit area at every density.
- The window title bar sits outside the scale, so the desktop window shell's own sizing is untouched.

## Not done

Grouping window per density, inline name and time at Compact, and a per-account sync of these choices.
