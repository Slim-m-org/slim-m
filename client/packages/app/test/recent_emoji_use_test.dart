// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The recently-used emoji shelf moves a picked emoji to the front, never
/// duplicates one, and caps its length. The picker test only checks that a
/// pick lands on the shelf; the move-to-front, the dedup, and the cap - the
/// things that keep the shelf short and in use-order - were untested.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/providers/recent_emoji.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a new emoji lands at the front, most recent first', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(recentEmojiProvider.notifier);

    await c.use('a');
    await c.use('b');

    expect(container.read(recentEmojiProvider), ['b', 'a']);
  });

  test('re-using an emoji moves it to the front without duplicating', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(recentEmojiProvider.notifier);
    await c.use('a');
    await c.use('b');

    await c.use('a');

    expect(container.read(recentEmojiProvider), ['a', 'b']);
  });

  test('the shelf is capped, dropping the least recently used', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final c = container.read(recentEmojiProvider.notifier);

    for (var i = 0; i < 25; i++) {
      await c.use('e$i');
    }

    final shelf = container.read(recentEmojiProvider);
    expect(shelf, hasLength(24));
    expect(shelf.first, 'e24');
    expect(shelf, isNot(contains('e0')));
  });
}
