// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a note's text is laid out, shared by the painter and by whatever answers a tap on it.
///
/// A task checkbox is a [WidgetSpan] holding a [NoteCheckMark] that is never inflated: the painter
/// only reads it for the box's state and source line, and draws the box itself in the gap the layout left.
/// A custom emoji is the same kind of gap, a [NoteEmojiMark] the painter fills with the emoji's bitmap.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'canvas_note_style.dart';

/// A note's padding, font size and line height, in world units.
const double noteWorldPad = 8;
const double noteWorldFontSize = 12;
const double noteLineHeight = 1.3;

/// Styles a note's text: markdown, mentions and emoji as spans over [base].
typedef NoteSpanBuilder = InlineSpan Function(String text, TextStyle base);

/// The box a placeholder checkbox leaves in the text, as a multiple of the font size.
const double noteCheckboxScale = 1;

/// The box an inline custom emoji leaves in the text, as a multiple of the font size.
const double noteEmojiScale = 1.2;

/// A note's text size in world units: the size its box allows, scaled by the step it was given.
double noteTextSizeOf(
  double fontSizeForBox,
  CanvasNoteStyle style,
) =>
    fontSizeForBox * canvasNoteSizeScale(style.size);

/// What a checkbox in the text knows: whether it is ticked and which source line holds it.
class NoteCheckMark extends SizedBox {
  const NoteCheckMark({super.key, required this.checked, required this.line});

  final bool checked;
  final int line;
}

/// A custom emoji in the text: its shortcode [name] and its [image] once the bitmap has loaded.
class NoteEmojiMark extends SizedBox {
  const NoteEmojiMark({super.key, required this.name, this.image});

  final String name;
  final ui.Image? image;
}

/// A span a tap opens: [url] is where it goes.
class NoteLinkSpan extends TextSpan {
  const NoteLinkSpan({required this.url, super.text, super.style});

  final String url;
}

/// One checkbox as laid out: its box inside the text area and the state it shows.
typedef NoteCheck = ({Rect rect, bool checked, int line});

/// One emoji as laid out: its box inside the text area and its bitmap, null while it loads.
typedef NoteEmoji = ({Rect rect, ui.Image? image});

final Expando<List<SizedBox>> _marksOf = Expando<List<SizedBox>>();

bool _isPlaceholderMark(Widget child) =>
    child is NoteCheckMark || child is NoteEmojiMark;

/// [spans] laid out at [fontSize] inside a [width] wide text area, wrapped at most [maxLines] lines.
TextPainter layoutNoteText(
  InlineSpan spans, {
  required double fontSize,
  required double width,
  int? maxLines,
}) {
  final marks = <SizedBox>[];
  spans.visitChildren((span) {
    if (span is WidgetSpan && _isPlaceholderMark(span.child)) {
      marks.add(span.child as SizedBox);
    }
    return true;
  });
  final painter = TextPainter(
    text: spans,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  );
  if (marks.isNotEmpty) {
    painter.setPlaceholderDimensions([
      for (final mark in marks)
        PlaceholderDimensions(
          size: Size.square(
            fontSize *
                (mark is NoteEmojiMark ? noteEmojiScale : noteCheckboxScale),
          ),
          alignment: PlaceholderAlignment.middle,
        ),
    ]);
  }
  painter.layout(maxWidth: width, minWidth: 0);
  _marksOf[painter] = marks;
  return painter;
}

/// Every checkbox in [painter]'s text, in reading order.
List<NoteCheck> noteChecksOf(TextPainter painter) {
  final marks = _marksOf[painter];
  final boxes = painter.inlinePlaceholderBoxes;
  if (marks == null || boxes == null) return const [];
  return [
    for (var i = 0; i < marks.length && i < boxes.length; i++)
      if (marks[i] case final NoteCheckMark mark)
        (rect: boxes[i].toRect(), checked: mark.checked, line: mark.line),
  ];
}

/// Every custom emoji in [painter]'s text, in reading order.
List<NoteEmoji> noteEmojisOf(TextPainter painter) {
  final marks = _marksOf[painter];
  final boxes = painter.inlinePlaceholderBoxes;
  if (marks == null || boxes == null) return const [];
  return [
    for (var i = 0; i < marks.length && i < boxes.length; i++)
      if (marks[i] case final NoteEmojiMark mark)
        (rect: boxes[i].toRect(), image: mark.image),
  ];
}

/// The link under [local], a point in the text area, or null.
String? noteLinkAt(TextPainter painter, Offset local) {
  final position = painter.getPositionForOffset(local);
  final span = painter.text?.getSpanForPosition(position);
  if (span is! NoteLinkSpan) return null;
  final boxes = painter.getBoxesForSelection(
    TextSelection(
        baseOffset: position.offset, extentOffset: position.offset + 1),
  );
  return boxes.any((box) => box.toRect().inflate(2).contains(local))
      ? span.url
      : null;
}
