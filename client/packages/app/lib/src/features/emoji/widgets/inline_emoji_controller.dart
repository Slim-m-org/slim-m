// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text controller that draws each completed custom `:name:` as its emoji, in place, while the text stays as typed.
///
/// A subclass may restyle the plain text through [displayText], which must keep every offset.
///
/// The shortcode's first character becomes the emoji and the rest is kept at no size, so every offset in the
/// field is still an offset in the text: the caret, a selection and a backspace all work on the real characters.
library;

import 'package:flutter/material.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show noteEmojiScale;

import '../../composer/widgets/composer_shortcode_convert.dart';
import 'custom_emoji_image.dart';

/// The size the characters behind an emoji are drawn at: invisible, yet still characters in the line.
const double _hiddenFontSize = 0.01;

class InlineEmojiController extends TextEditingController {
  InlineEmojiController({super.text, required this.index});

  /// The deployment's custom emoji, read at each paint so one that loads later still shows.
  final Map<String, String> Function() index;

  /// The text as it is drawn: one code unit for each of the typed text's, so offsets are unchanged.
  @protected
  String displayText(String typed) => typed;

  /// Keeps the caret out of a shortcode's hidden characters and takes a backspace at its edge as one delete.
  @override
  set value(TextEditingValue next) =>
      super.value = _whole(value, next) ?? _outsideEmoji(value, next);

  TextEditingValue? _whole(TextEditingValue old, TextEditingValue next) {
    final caret = next.selection;
    if (!caret.isCollapsed ||
        !old.selection.isCollapsed ||
        next.text.length != old.text.length - 1) {
      return null;
    }
    final from = old.selection.baseOffset;
    for (final range in customEmojiRangesIn(old.text, index())) {
      final backspace = from == range.end && caret.baseOffset == from - 1;
      final forward = from == range.start && caret.baseOffset == from;
      if (backspace || forward) {
        return next.copyWith(
          text: old.text.replaceRange(range.start, range.end, ''),
          selection: TextSelection.collapsed(offset: range.start),
          composing: TextRange.empty,
        );
      }
    }
    return null;
  }

  TextEditingValue _outsideEmoji(TextEditingValue old, TextEditingValue next) {
    final at = next.selection.baseOffset;
    if (!next.selection.isCollapsed || _composes(next.composing)) return next;
    for (final range in customEmojiRangesIn(next.text, index())) {
      if (at <= range.start || at >= range.end) continue;
      final before = old.text == next.text ? old.selection.baseOffset : at;
      final step = at - before;
      final forward = step.abs() > 1
          ? at - range.start > range.end - at
          : step > 0;
      return next.copyWith(
        selection: TextSelection.collapsed(
          offset: forward ? range.end : range.start,
        ),
      );
    }
    return next;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = withComposing ? value.composing : TextRange.empty;
    final ranges = [
      for (final range in customEmojiRangesIn(text, index()))
        if (!_overlaps(range, composing)) range,
    ];
    final shown = displayText(text);
    if (ranges.isEmpty) {
      return TextSpan(
        style: style,
        children: _plain(shown, 0, shown.length, composing, style),
      );
    }
    final size = (style?.fontSize ?? 14) * noteEmojiScale;
    var at = 0;
    final children = <InlineSpan>[];
    for (final range in ranges) {
      children.addAll(_plain(shown, at, range.start, composing, style));
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
            text: shown.substring(range.start + 1, range.end),
            style: const TextStyle(fontSize: _hiddenFontSize),
          ),
        );
      at = range.end;
    }
    children.addAll(_plain(shown, at, shown.length, composing, style));
    return TextSpan(style: style, children: children);
  }

  bool _composes(TextRange composing) =>
      composing.isValid && !composing.isCollapsed;

  bool _overlaps(CustomEmojiRange range, TextRange composing) =>
      _composes(composing) &&
      composing.start < range.end &&
      composing.end > range.start;

  /// The text from [from] to [to], with the part the keyboard is composing underlined as a field does.
  List<InlineSpan> _plain(
    String shown,
    int from,
    int to,
    TextRange composing,
    TextStyle? style,
  ) {
    if (from >= to) return const [];
    final inStart = composing.isValid ? composing.start.clamp(from, to) : to;
    final inEnd = composing.isValid ? composing.end.clamp(from, to) : to;
    if (inStart >= inEnd) return [TextSpan(text: shown.substring(from, to))];
    return [
      if (inStart > from) TextSpan(text: shown.substring(from, inStart)),
      TextSpan(
        text: shown.substring(inStart, inEnd),
        style: const TextStyle(decoration: TextDecoration.underline),
      ),
      if (inEnd < to) TextSpan(text: shown.substring(inEnd, to)),
    ];
  }
}
