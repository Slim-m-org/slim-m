// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text controller that draws each completed custom `:name:` as its emoji, in place, while the text stays as typed.
///
/// The shortcode's first character becomes the emoji and the rest is kept at no size, so every offset in the
/// field is still an offset in the text: the caret, a selection and a backspace all work on the real characters.
library;

import 'package:flutter/material.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show noteEmojiScale;

import '../../composer/widgets/composer_shortcode_convert.dart';
import '../../emoji/widgets/custom_emoji_image.dart';

/// The size the characters behind an emoji are drawn at: invisible, yet still characters in the line.
const double _hiddenFontSize = 0.01;

class InlineEmojiController extends TextEditingController {
  InlineEmojiController({super.text, required this.index});

  /// The deployment's custom emoji, read at each paint so one that loads later still shows.
  final Map<String, String> Function() index;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final ranges = value.composing.isValid && withComposing
        ? const <CustomEmojiRange>[]
        : customEmojiRangesIn(text, index());
    if (ranges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final size = (style?.fontSize ?? 14) * noteEmojiScale;
    var at = 0;
    final children = <InlineSpan>[];
    for (final range in ranges) {
      if (range.start > at) {
        children.add(TextSpan(text: text.substring(at, range.start)));
      }
      children
        ..add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: CustomEmojiImage(
              emojiId: range.id,
              label: ':${range.name}:',
              size: size,
            ),
          ),
        )
        ..add(
          TextSpan(
            text: text.substring(range.start + 1, range.end),
            style: const TextStyle(fontSize: _hiddenFontSize),
          ),
        );
      at = range.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: children);
  }
}
