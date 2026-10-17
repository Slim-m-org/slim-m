// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The [AppAvatarShape.square] placeholder for a bot with no picture:
/// initials, the same source [AppAvatar]'s own round face draws them from,
/// since a blank box read as broken rather than "no icon set yet".
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

Widget botAvatarPlaceholder(BuildContext context, String name) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  final initials = initialsFor(name);
  if (initials.isEmpty) return const SizedBox.shrink();
  return Text(
    initials,
    style: AppText.code.copyWith(fontSize: 11, color: tokens.textSecondary),
  );
}
