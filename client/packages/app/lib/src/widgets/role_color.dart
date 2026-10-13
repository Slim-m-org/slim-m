// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role's display colour: the palette entry a role manager chose, or one
/// hashed from the role's id when nobody has chosen yet.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart' show stableIndexFor;

/// A colour a role can wear, with the name a screen reader says for it.
typedef RolePaletteEntry = ({Color color, String name});

/// Ten entries, matching the server's `ROLE_COLOR_COUNT`. The first six are
/// the hues every role was hashed to before colours could be chosen, so an
/// unchosen role keeps the colour it always had. Kept apart from `AppAvatar`'s
/// tints so a role dot never reads as an avatar.
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

/// How many of [rolePalette]'s entries an unchosen role is hashed across.
const int _hashedEntries = 6;

/// The palette index a role shows: its chosen [color] when it is in range,
/// otherwise the one hashed from [roleId].
int rolePaletteIndex(String roleId, int? color) =>
    color != null && color >= 0 && color < rolePalette.length
    ? color
    : stableIndexFor(roleId, _hashedEntries);

Color roleColor(String roleId, {int? color}) =>
    rolePalette[rolePaletteIndex(roleId, color)].color;
