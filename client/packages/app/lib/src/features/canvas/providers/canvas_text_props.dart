// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a text box carries: its content, its font step and its colour, and the last style chosen.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../hidden_characters.dart';

/// Matches the server's `MAX_TEXT_CHARS`.
const int maxTextBoxChars = 500;

/// The font steps offered, smallest first; each equals a step of the design type scale.
const canvasTextSizeKeys = ['small', 'medium', 'large'];

/// The design-scale size behind each step, which the canvas package mirrors in [canvasTextFontSizes].
final canvasTextScaleSizes = {
  'small': AppText.ui.fontSize!,
  'medium': AppText.heading.fontSize!,
  'large': AppText.title.fontSize!,
};

/// The step labels a screen reader and a tooltip use.
const canvasTextSizeLabels = {
  'small': 'Small',
  'medium': 'Medium',
  'large': 'Large',
};

@immutable
class CanvasTextProps {
  const CanvasTextProps({
    required this.text,
    this.size = canvasDefaultTextSize,
    this.colorKey = canvasDefaultTextColor,
  });

  /// Reads wire props; null when the text is missing, so a malformed row paints nothing.
  static CanvasTextProps? fromWire(Map<String, dynamic> props) {
    final text = props['text'];
    if (text is! String) return null;
    final size = props['size'];
    final color = props['color'];
    return CanvasTextProps(
      text: text,
      size: size is String && canvasTextFontSizes.containsKey(size)
          ? size
          : canvasDefaultTextSize,
      colorKey: color is String && color.isNotEmpty
          ? color
          : canvasDefaultTextColor,
    );
  }

  final String text;
  final String size;
  final String colorKey;

  Map<String, dynamic> toWire() => {
    'text': text,
    'size': size,
    'color': colorKey,
  };

  CanvasTextProps copyWith({String? text, String? size, String? colorKey}) =>
      CanvasTextProps(
        text: text ?? this.text,
        size: size ?? this.size,
        colorKey: colorKey ?? this.colorKey,
      );

  @override
  bool operator ==(Object other) =>
      other is CanvasTextProps &&
      other.text == text &&
      other.size == size &&
      other.colorKey == colorKey;

  @override
  int get hashCode => Object.hash(text, size, colorKey);
}

/// [text] as the server will accept it: hidden and direction characters gone, tabs as spaces, line breaks kept.
String cleanTextBoxInput(String text) {
  final out = StringBuffer();
  for (final c in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').runes) {
    if (c == 0x0A) {
      out.write('\n');
    } else if (c == 0x09) {
      out.write(' ');
    } else if (!isHiddenCharacter(c)) {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// The size and colour the next new text box starts with, kept across opens of the canvas.
final canvasLastTextStyleProvider =
    StateProvider<({String size, String colorKey})>(
      (ref) => (size: canvasDefaultTextSize, colorKey: canvasDefaultTextColor),
    );
