// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the composer reads off its text to decide a rebuild is worth it.
library;

import 'composer_extras.dart';

class ComposerTextStats {
  const ComposerTextStats({
    required this.hasText,
    required this.hasSendableText,
    required this.charCount,
    required this.overBy,
  });

  factory ComposerTextStats.of(String text) {
    final charCount = text.runes.length;
    return ComposerTextStats(
      // Untrimmed, so typed spaces hide the placeholder.
      hasText: text.isNotEmpty,
      // Trimmed, because the send path drops whitespace-only text.
      hasSendableText: text.trim().isNotEmpty,
      charCount: charCount,
      overBy: messageLengthOverage(charCount),
    );
  }

  final bool hasText;
  final bool hasSendableText;

  /// How long the text is and how far over the limit it sits, if at all.
  final int charCount;
  final int? overBy;

  /// The count itself only matters while the counter is or was on screen.
  bool changedFrom(ComposerTextStats before) =>
      hasText != before.hasText ||
      hasSendableText != before.hasSendableText ||
      overBy != before.overBy ||
      ((messageCounterVisible(charCount) ||
              messageCounterVisible(before.charCount)) &&
          charCount != before.charCount);
}
