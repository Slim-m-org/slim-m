// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The colours a mention draws with, named once so a test can hold every theme
/// to the same visibility floor instead of each theme being eyeballed.
library;

import 'package:flutter/painting.dart';

import 'app_tokens.dart';

extension MentionColours on AppTokens {
  /// The row of a message that mentions you.
  Color get mentionRowFill => accentSoft;

  /// The bar on that row's left edge.
  Color get mentionRowBar => accent;

  /// The @pill sits on [mentionRowFill] in a mentioned row, so its fill alone
  /// vanishes there; this outline keeps it a pill on any row.
  Color get mentionPillOutline => Color.alphaBlend(
        accent.withValues(alpha: 0.55),
        accentSoft,
      );
}
