// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `:name:` a hover or long-press shows for an emoji, from the same
/// catalog the picker's preview footer reads.
library;

import 'package:emojis/emoji.dart';

import 'custom_emoji_image.dart' show customEmojiIdFor;

final Map<String, String> _shortNames = () {
  final names = <String, String>{};
  for (final emoji in Emoji.all()) {
    names.putIfAbsent(emoji.char, () => emoji.shortName);
    names.putIfAbsent(_plain(emoji.char), () => emoji.shortName);
  }
  return names;
}();

String _plain(String glyph) => glyph.replaceAll('\u{FE0F}', '');

/// `:short_name:` for a standard emoji glyph, ignoring the presentation
/// selector and falling back to the toneless emoji for a skin-tone variant;
/// null for anything the catalog does not name.
String? standardEmojiShortcode(String glyph) {
  final name =
      _shortNames[glyph] ??
      _shortNames[_plain(glyph)] ??
      _shortNames[_plain(Emoji.stabilize(glyph))];
  return name == null ? null : ':$name:';
}

/// The name to show for a reaction or inline token: a custom emoji's own
/// `:shortcode:`, else the standard glyph's.
String? emojiDisplayName(String token, Map<String, String> customEmoji) {
  if (customEmojiIdFor(token, customEmoji) != null) return token;
  return standardEmojiShortcode(token);
}
