// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A soundboard clip keeps its emoji as one standard emoji or a custom emoji's
/// id; these read that back for drawing and naming, and turn a picked
/// `:shortcode:` into the id the server stores.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/stored_emoji.dart';

void main() {
  const partyId = '01900000-0000-7000-8000-00000000e001';
  const index = {'party_parrot': partyId, 'blob': 'e-blob'};

  test('an id, a known id or a custom shortcode is a custom emoji', () {
    expect(storedCustomEmojiId(partyId, const {}), partyId);
    expect(storedCustomEmojiId('e-blob', index), 'e-blob');
    expect(storedCustomEmojiId(':party_parrot:', index), partyId);
  });

  test('a standard emoji is not a custom one', () {
    expect(storedCustomEmojiId('\u{1F4EF}', index), isNull);
    expect(storedCustomEmojiId(':trumpet:', index), isNull);
  });

  test(
    "a picked custom shortcode is stored as its id, anything else as is",
    () {
      expect(storableEmoji(':party_parrot:', index), partyId);
      expect(storableEmoji('\u{1F3BA}', index), '\u{1F3BA}');
    },
  );

  test('a stored emoji is named by its shortcode', () {
    expect(storedEmojiName(partyId, index), ':party_parrot:');
    expect(storedEmojiName('\u{1F4EF}', index), ':postal_horn:');
    expect(
      storedEmojiName('01900000-0000-7000-8000-00000000ffff', index),
      isNull,
    );
  });
}
