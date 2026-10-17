// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `effectiveCategory` picks which emoji tab is actually shown from the one the
/// user chose (null until they pick) and whether any custom emoji exist. Two
/// rules matter and neither was tested: with no pick it opens on custom only
/// when there are custom emoji, and a chosen custom tab falls back to smileys
/// if the last custom emoji is deleted while the picker is open - without that
/// fallback the picker sits on an empty tab.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

void main() {
  test('with no pick, custom opens only when there are custom emoji', () {
    expect(effectiveCategory(null, hasCustom: true), EmojiCategory.custom);
    expect(
      effectiveCategory(null, hasCustom: false),
      EmojiCategory.smileysEmotion,
    );
  });

  test('a chosen custom tab falls back to smileys once it is empty', () {
    expect(
      effectiveCategory(EmojiCategory.custom, hasCustom: false),
      EmojiCategory.smileysEmotion,
    );
    expect(
      effectiveCategory(EmojiCategory.custom, hasCustom: true),
      EmojiCategory.custom,
    );
  });

  test('any other chosen tab is honored regardless of custom emoji', () {
    expect(
      effectiveCategory(EmojiCategory.recent, hasCustom: false),
      EmojiCategory.recent,
    );
    expect(
      effectiveCategory(EmojiCategory.smileysEmotion, hasCustom: true),
      EmojiCategory.smileysEmotion,
    );
  });
}
