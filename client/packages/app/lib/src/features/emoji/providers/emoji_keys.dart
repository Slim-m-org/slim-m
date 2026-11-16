// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading the keys an emoji is stored under, with no widgets, so a provider can resolve one too.
library;

/// The emoji id a `:shortcode:` names, or null when [token] names none of the
/// deployment's own. [index] is `customEmojiIndexProvider`'s name-to-id map.
///
/// The one place that reads the colon delimiters back off a token, so a
/// message body and a reaction chip cannot drift apart about what resolves.
/// A miss is the normal case (most colon runs name nothing) and returns null
/// rather than throwing, which leaves the caller showing the text it had. It
/// judges the token alone: whether the text around one reads as an emoji at
/// all is the caller's, since only a message body has text around it.
String? customEmojiIdFor(String token, Map<String, String> index) {
  if (token.length < 3 || !token.startsWith(':') || !token.endsWith(':')) {
    return null;
  }
  return index[token.substring(1, token.length - 1).toLowerCase()];
}

final _emojiId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The custom emoji [value] names, by id or `:shortcode:`, or null for a
/// standard one. [index] is `customEmojiIndexProvider`'s name-to-id map.
///
/// An id the catalog has not loaded yet still counts, so it draws as an image.
String? storedCustomEmojiId(String value, Map<String, String> index) {
  if (_emojiId.hasMatch(value) || index.containsValue(value)) return value;
  return customEmojiIdFor(value, index);
}
