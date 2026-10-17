// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client's emoji-name preview must agree with the server, character for
/// character, or the name shown before an upload is not the name stored after
/// it.
///
/// Every case below is lifted from `normalize_name`'s own tests in
/// `crates/slimm-server/src/emoji.rs`, so the two suites fail together if
/// either side is changed alone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_name.dart';

void main() {
  test('a name is reduced to what can be typed between colons', () {
    expect(normalizeEmojiName('Big Smile'), 'big_smile');
    expect(normalizeEmojiName('party-parrot'), 'party_parrot');
    expect(normalizeEmojiName('  OK  '), 'ok');
    expect(normalizeEmojiName(':::'), '');
    expect(normalizeEmojiName(''), '');
  });

  test('the length ceiling matches the server, measured after normalising', () {
    expect(isUsableEmojiName(normalizeEmojiName('x' * 32)), isTrue);
    expect(isUsableEmojiName(normalizeEmojiName('x' * 33)), isFalse);
    // What was typed is 40 characters and still accepted: the ceiling is
    // applied to what survives normalising, exactly as the server applies it.
    final typed = '${'!' * 5}${'x' * 30}${'!' * 5}';
    expect(typed.length, 40);
    expect(isUsableEmojiName(normalizeEmojiName(typed)), isTrue);
  });

  test('spellings that normalise together collide rather than coexisting', () {
    expect(normalizeEmojiName('Big Smile'), normalizeEmojiName('big-smile'));
  });

  /// The upload sends the normalised name and the server normalises again;
  /// that is only sound if the second pass changes nothing.
  test('normalising an already normalised name changes nothing', () {
    for (final raw in ['Big Smile', 'party-parrot', '  OK  ', 'a1_b2']) {
      final once = normalizeEmojiName(raw);
      expect(normalizeEmojiName(once), once);
    }
  });

  /// The server lowercases with `to_ascii_lowercase`, which leaves non-ASCII
  /// alone for the filter to drop. Dart's own `toLowerCase` folds this to an
  /// `i` plus a combining mark, and the `i` would survive: the preview would
  /// promise `:i:` for something the server stores as nothing at all.
  test('non-ascii is dropped rather than case-folded into ascii', () {
    expect(normalizeEmojiName('İ'), '');
    expect(normalizeEmojiName('café'), 'caf');
    expect(normalizeEmojiName('ÉCLAIR'), 'clair');
  });

  test('a shortcode is the Slack convention, colons and no spaces', () {
    expect(emojiShortcode('party_parrot'), ':party_parrot:');
  });
}
