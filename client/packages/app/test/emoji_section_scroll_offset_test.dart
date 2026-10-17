// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `emojiSectionScrollOffset` is the rail's jump-to-section math: an
/// estimate from item counts alone, deliberately not a real layout
/// measurement, so a jump works even for a section nothing has built yet.
/// See `emoji_sectioned_grid.dart`'s own doc comment for why a jump rather
/// than live scroll-position tracking.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_sectioned_grid.dart';

List<PickerEmoji> _fakeEmoji(int count) => [
  for (var i = 0; i < count; i++)
    DeploymentEmoji(
      CustomEmoji(id: 'e$i', name: 'e$i', uploaderId: 'u1', createdAt: 1),
    ),
];

void main() {
  test("the leading section's own offset is zero", () {
    final sections = [
      EmojiSection(category: EmojiCategory.custom, emoji: _fakeEmoji(4)),
      EmojiSection(category: EmojiCategory.recent, emoji: _fakeEmoji(4)),
    ];

    expect(
      emojiSectionScrollOffset(
        category: EmojiCategory.custom,
        sections: sections,
        crossAxisExtent: 280,
      ),
      0,
    );
  });

  test('a later section lands past every row the ones above it take', () {
    // One column at this width: 40 (cellExtent) + 4 (spacing) = 44 per row.
    const crossAxisExtent = EmojiGrid.cellExtent;
    final sections = [
      EmojiSection(category: EmojiCategory.custom, emoji: _fakeEmoji(3)),
      EmojiSection(category: EmojiCategory.recent, emoji: _fakeEmoji(1)),
    ];

    final offset = emojiSectionScrollOffset(
      category: EmojiCategory.recent,
      sections: sections,
      crossAxisExtent: crossAxisExtent,
    );

    // 3 rows of 1 column above it, plus the header and the gap after it.
    const spacing = 4.0;
    const expected =
        EmojiSectionedGrid.headerHeight +
        3 * (EmojiGrid.cellExtent + spacing) +
        EmojiSectionedGrid.sectionGap;
    expect(offset, expected);
  });

  test('a wider cross axis packs more columns and so a shorter offset', () {
    final sections = [
      EmojiSection(category: EmojiCategory.custom, emoji: _fakeEmoji(8)),
      EmojiSection(category: EmojiCategory.recent, emoji: _fakeEmoji(1)),
    ];

    final narrow = emojiSectionScrollOffset(
      category: EmojiCategory.recent,
      sections: sections,
      crossAxisExtent: EmojiGrid.cellExtent,
    );
    final wide = emojiSectionScrollOffset(
      category: EmojiCategory.recent,
      sections: sections,
      crossAxisExtent: EmojiGrid.cellExtent * 4,
    );

    expect(
      wide,
      lessThan(narrow),
      reason: 'more columns means fewer rows for the same 8 tiles',
    );
  });

  test('a category not in the list falls off the end rather than throwing', () {
    final sections = [
      EmojiSection(category: EmojiCategory.custom, emoji: _fakeEmoji(2)),
    ];

    expect(
      () => emojiSectionScrollOffset(
        category: EmojiCategory.flags,
        sections: sections,
        crossAxisExtent: 280,
      ),
      returnsNormally,
    );
  });
}
