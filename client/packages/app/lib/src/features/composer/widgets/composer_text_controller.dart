// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's text controller: typed spaces wrap onto the next line
/// instead of hanging past the field's right edge, and custom emoji draw in place.
library;

import '../../emoji/widgets/inline_emoji_controller.dart';

const _space = 0x20;
const _noBreakSpace = 0xA0;

/// [text] with every second space of a run drawn as a no-break space, one
/// code unit for one, so offsets are unchanged.
///
/// The line breaker lets trailing spaces hang past the line's end, which
/// left the caret pinned to the right edge however many were typed. A
/// no-break space never hangs, and the plain space before each one keeps a
/// break opportunity, so a run of spaces moves onto the next line a space or
/// two at a time instead of all at once.
String wrappingSpaces(String text) {
  if (!text.contains('  ')) return text;
  final units = text.codeUnits.toList();
  var run = 0;
  for (var i = 0; i < units.length; i++) {
    run = units[i] == _space ? run + 1 : 0;
    if (run.isEven && run > 0) units[i] = _noBreakSpace;
  }
  return String.fromCharCodes(units);
}

/// Draws [wrappingSpaces] and each completed custom `:name:` as its emoji, while [text] and every offset stay what was typed.
class ComposerTextController extends InlineEmojiController {
  ComposerTextController({super.text, Map<String, String> Function()? index})
    : super(index: index ?? _noEmoji);

  static Map<String, String> _noEmoji() => const {};

  @override
  String displayText(String typed) => wrappingSpaces(typed);
}
