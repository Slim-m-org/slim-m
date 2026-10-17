// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `recentEmojiEntries` resolves the recently-used shelf's stored tokens back
/// into pickable emoji. The picker widget test covers a used emoji showing up,
/// but not the case that actually breaks quietly: a stored token that no
/// longer resolves - a custom emoji since deleted, or anything unrecognized -
/// must be dropped, not rendered as a hole, and the order the tokens were used
/// in must survive.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

const _grinningFace = '\u{1F600}';

CustomEmoji _custom(String name) =>
    CustomEmoji(id: 'e-$name', name: name, uploaderId: 'u1', createdAt: 1);

void main() {
  test('a unicode token and a live custom shortcode both resolve', () {
    final entries = recentEmojiEntries(
      [_grinningFace, ':party:'],
      [_custom('party')],
    );

    expect(entries, hasLength(2));
    expect(entries[0], isA<UnicodeEmoji>());
    expect(entries[1], isA<DeploymentEmoji>());
    expect((entries[1] as DeploymentEmoji).emoji.name, 'party');
  });

  test('a token that no longer resolves is dropped, keeping the order', () {
    final entries = recentEmojiEntries(
      // A deleted custom shortcode and a garbage token sit between two good ones.
      [_grinningFace, ':gone:', 'not-an-emoji', ':party:'],
      [_custom('party')],
    );

    expect(entries, hasLength(2));
    expect(entries[0], isA<UnicodeEmoji>());
    expect((entries[1] as DeploymentEmoji).emoji.name, 'party');
  });

  test('an empty history resolves to nothing', () {
    expect(recentEmojiEntries(const [], const []), isEmpty);
  });
}
