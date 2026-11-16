// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns a standard `:shortcode:` back into its codepoint.
library;

import 'package:emojis/emoji.dart';

/// The codepoint a standard emoji's `:shortcode:` names, or null for any other token.
///
/// The server keys a reaction on whatever string a client sent, so an API caller or bot
/// that sent `:anger:` left a key the picker itself never produces.
String? standardEmojiFor(String token) {
  if (token.length < 3 || !token.startsWith(':') || !token.endsWith(':')) {
    return null;
  }
  final name = token.substring(1, token.length - 1).toLowerCase();
  return Emoji.byShortName(name)?.char;
}

final RegExp _storableName = RegExp(r'^[a-z0-9_]{1,32}$');

final Set<String> _standardNames = {
  for (final emoji in Emoji.all())
    if (emoji.emojiGroup != EmojiGroup.component)
      emoji.shortName.toLowerCase().replaceAll(RegExp(r'[ -]'), '_'),
}..removeWhere((name) => !_storableName.hasMatch(name));

/// Every such name, for the test that holds it equal to the server's list.
Set<String> get standardEmojiNames => _standardNames;

/// Whether a normalised custom emoji name is a standard emoji's shortcode.
///
/// Mirrors `emoji::builtin` on the server, which refuses such a name.
bool isStandardEmojiName(String name) => _standardNames.contains(name);
