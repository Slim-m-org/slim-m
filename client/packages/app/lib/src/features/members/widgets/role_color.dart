// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role's display colour: the palette entry a role manager chose, or none,
/// which every surface draws as the same neutral grey dot, the way Discord
/// leaves an uncoloured role grey.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart'
    show AppListRow, AppTokens, nudgeForContrast;

/// A colour a role can wear, with the name a screen reader says for it.
typedef RolePaletteEntry = ({Color color, String name});

/// Ten entries, matching the server's `ROLE_COLOR_COUNT`, in the order the
/// server's stored indices name them. Kept apart from `AppAvatar`'s tints so a
/// role dot never reads as an avatar.
const List<RolePaletteEntry> rolePalette = [
  (color: Color(0xFFC9A227), name: 'Gold'),
  (color: Color(0xFF58B4D8), name: 'Sky'),
  (color: Color(0xFF7A8FA6), name: 'Slate'),
  (color: Color(0xFF8A6FA8), name: 'Violet'),
  (color: Color(0xFF6FA88A), name: 'Sage'),
  (color: Color(0xFFA87A6F), name: 'Clay'),
  (color: Color(0xFFC75B5B), name: 'Red'),
  (color: Color(0xFFD08A3E), name: 'Orange'),
  (color: Color(0xFFC46FA0), name: 'Pink'),
  (color: Color(0xFF4FA3A0), name: 'Teal'),
];

/// WCAG AA for body text, which a coloured name still is.
const double _nameTextRatio = 4.5;

/// The palette index a role manager chose, or null for none or one out of range.
int? chosenRoleIndex(int? color) =>
    color != null && color >= 0 && color < rolePalette.length ? color : null;

/// The colour a role manager chose for a role, or null when nobody has.
Color? chosenRoleColor(int? color) => switch (chosenRoleIndex(color)) {
  final index? => rolePalette[index].color,
  null => null,
};

/// A role's dot wherever one is drawn, admin and member surfaces alike.
Color roleDotColor(int? color, AppTokens tokens) =>
    chosenRoleColor(color) ?? tokens.borderStrong;

/// [member]'s name colour on [surface]: their highest role with a chosen
/// colour, moved just far enough to read; null keeps the default text colour.
Color? memberNameColor(api.UserProfile? member, Color surface) {
  for (final color in member?.roleColors ?? const <int?>[]) {
    final chosen = chosenRoleColor(color);
    if (chosen != null) {
      return nudgeForContrast(chosen, surface, minRatio: _nameTextRatio);
    }
  }
  return null;
}

/// An offline row's name on [surface]: [neutral] at the row's offline opacity,
/// and a [roleColour] at that opacity over it, so the colour greys out rather
/// than only darkening; each moved back just far enough to stay AA.
Color offlineNameColor(
  Color? roleColour, {
  required Color neutral,
  required Color surface,
}) {
  Color dim(Color colour, Color under) => nudgeForContrast(
    Color.alphaBlend(colour.withValues(alpha: AppListRow.mutedOpacity), under),
    surface,
    minRatio: _nameTextRatio,
  );
  final grey = dim(neutral, surface);
  return roleColour == null ? grey : dim(roleColour, grey);
}
