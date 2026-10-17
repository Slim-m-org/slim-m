// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `customEmojiIdFor` turns a `:shortcode:` token in message text into the
/// custom emoji id that renders it, and it was untested. The delimiters and
/// the case fold are what make a typed `:Party:` find the uploaded `party`,
/// and the guards are what stop a bare word or a half-open token resolving to
/// anything at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';

void main() {
  const index = {'party': 'e-party'};

  test('a delimited shortcode resolves to its id, case-insensitively', () {
    expect(customEmojiIdFor(':party:', index), 'e-party');
    expect(customEmojiIdFor(':PARTY:', index), 'e-party');
  });

  test('a shortcode not in the index resolves to null', () {
    expect(customEmojiIdFor(':nope:', index), isNull);
  });

  test('a token without both colons is not a shortcode', () {
    expect(customEmojiIdFor('party', index), isNull);
    expect(customEmojiIdFor(':party', index), isNull);
    expect(customEmojiIdFor('party:', index), isNull);
    // Strips to "party" if the ends are cut blindly; the colons make it, not the text.
    expect(customEmojiIdFor('xpartyx', index), isNull);
  });

  test('a token too short to hold a name is rejected', () {
    expect(customEmojiIdFor('::', index), isNull);
    expect(customEmojiIdFor(':', index), isNull);
  });
}
