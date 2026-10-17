// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `pickerTabs` decides which emoji category tabs the picker shows: the custom
/// and recent tabs appear only when they have something in them, custom ahead
/// of recent, and the standard categories always follow. A tab shown while
/// empty lands the user on a blank grid, so the conditions are worth pinning.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

void main() {
  test('custom and recent appear only when they have content', () {
    final none = pickerTabs(hasCustom: false, hasRecent: false);
    expect(none, isNot(contains(EmojiCategory.custom)));
    expect(none, isNot(contains(EmojiCategory.recent)));

    expect(
      pickerTabs(hasCustom: true, hasRecent: false),
      contains(EmojiCategory.custom),
    );
    expect(
      pickerTabs(hasCustom: false, hasRecent: true),
      contains(EmojiCategory.recent),
    );
  });

  test('custom leads, then recent, when both are present', () {
    final both = pickerTabs(hasCustom: true, hasRecent: true);
    expect(both.first, EmojiCategory.custom);
    expect(
      both.indexOf(EmojiCategory.custom),
      lessThan(both.indexOf(EmojiCategory.recent)),
    );
  });

  test('the standard categories are always there', () {
    expect(
      pickerTabs(hasCustom: false, hasRecent: false),
      contains(EmojiCategory.smileysEmotion),
    );
  });
}
