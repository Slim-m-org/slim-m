// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mark for a person who is no longer reachable, drawn where the presence
/// dot would be.
library;

import 'package:flutter/material.dart';

import '../../app_icons.dart';
import '../../app_tokens.dart';

/// Why a person has no presence: they [left] the Space, or their account is [deleted].
///
/// Kept apart from `AppPresence`, which only ever describes someone who is here.
enum AppAvatarBadge {
  left(AppIcons.presenceLeft, 'left the Space'),
  deleted(AppIcons.presenceDeleted, 'deleted account');

  const AppAvatarBadge(this.icon, this.word);

  final IconData icon;

  /// What a screen reader adds after the name.
  final String word;
}

/// The badge's glyph in a secondary text colour; the silhouette carries the meaning, not the colour.
class AppAvatarBadgeMark extends StatelessWidget {
  const AppAvatarBadgeMark({
    super.key,
    required this.badge,
    required this.size,
  });

  final AppAvatarBadge badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Icon(badge.icon, size: size, color: tokens.textSecondary);
  }
}
