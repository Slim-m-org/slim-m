// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's text controller: typed spaces wrap onto the next line
/// instead of hanging past the field's right edge.
library;

import 'package:flutter/material.dart';

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

/// Draws [wrappingSpaces] while [text] and every offset stay what was typed.
class ComposerTextController extends TextEditingController {
  ComposerTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final shown = wrappingSpaces(text);
    final composing = value.composing;
    if (!withComposing || !value.isComposingRangeValid) {
      return TextSpan(style: style, text: shown);
    }
    const underline = TextStyle(decoration: TextDecoration.underline);
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: shown.substring(0, composing.start)),
        TextSpan(
          style: style?.merge(underline) ?? underline,
          text: shown.substring(composing.start, composing.end),
        ),
        TextSpan(text: shown.substring(composing.end)),
      ],
    );
  }
}
