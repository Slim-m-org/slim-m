// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `pickerSections` is the browse view's own data: every `pickerTabs` entry
/// folded together with its own `pickerResults`, empty ones dropped. The
/// continuous scrollable and its rail both read this rather than filtering
/// a single category on demand.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

CustomEmoji _custom(String name) =>
    CustomEmoji(id: 'e-$name', name: name, uploaderId: 'u1', createdAt: 1);

void main() {
  test('every non-empty pickerTabs category becomes a section, in order', () {
    final sections = pickerSections(recent: const [], custom: const []);

    expect(sections.map((s) => s.category), [
      EmojiCategory.smileysEmotion,
      EmojiCategory.peopleBody,
      EmojiCategory.animalsNature,
      EmojiCategory.foodDrink,
      EmojiCategory.activities,
      EmojiCategory.travelPlaces,
      EmojiCategory.objects,
      EmojiCategory.symbols,
      EmojiCategory.flags,
    ]);
    for (final section in sections) {
      expect(section.emoji, isNotEmpty);
    }
  });

  test('a deployment with custom emoji leads with that section', () {
    final sections = pickerSections(
      recent: const [],
      custom: [_custom('party_parrot')],
    );

    expect(sections.first.category, EmojiCategory.custom);
    expect(sections.first.emoji.single.token, ':party_parrot:');
  });

  test('a history adds a recent section right after custom', () {
    final sections = pickerSections(
      recent: const ['\u{1F600}'],
      custom: [_custom('shipit')],
    );

    expect(sections[0].category, EmojiCategory.custom);
    expect(sections[1].category, EmojiCategory.recent);
  });

  test('no custom emoji and no history means neither section exists', () {
    final sections = pickerSections(recent: const [], custom: const []);

    expect(
      sections.map((s) => s.category),
      isNot(contains(EmojiCategory.custom)),
    );
    expect(
      sections.map((s) => s.category),
      isNot(contains(EmojiCategory.recent)),
    );
  });

  test("recent's browse header reads Discord's own wording, distinct from its "
      'rail tooltip', () {
    expect(EmojiCategory.recent.sectionLabel, 'Frequently used');
    expect(EmojiCategory.recent.label, 'Recently used');
    expect(EmojiCategory.smileysEmotion.sectionLabel, 'Smileys and emotion');
  });
}
