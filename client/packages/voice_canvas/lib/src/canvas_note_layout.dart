// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a note's text is laid out, shared by the painter and by whatever answers a tap on it.
///
/// A task checkbox is a [WidgetSpan] holding a [NoteCheckMark] that is never inflated: the painter
/// only reads it for the box's state and source line, and draws the box itself in the gap the layout left.
library;

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

/// A span a tap opens: [url] is where it goes.
class NoteLinkSpan extends TextSpan {
  const NoteLinkSpan({required this.url, super.text, super.style});

  final String url;
}

/// One checkbox as laid out: its box inside the text area and the state it shows.
typedef NoteCheck = ({Rect rect, bool checked, int line});

final Expando<List<NoteCheckMark>> _marksOf = Expando<List<NoteCheckMark>>();

/// [spans] laid out at [fontSize] inside a [width] wide text area, wrapped at most [maxLines] lines.
TextPainter layoutNoteText(
  InlineSpan spans, {
  required double fontSize,
  required double width,
  int? maxLines,
}) {
  final marks = <NoteCheckMark>[];
  spans.visitChildren((span) {
    if (span is WidgetSpan && span.child is NoteCheckMark) {
      marks.add(span.child as NoteCheckMark);
    }
    return true;
  });
  final side = fontSize * noteCheckboxScale;
  final painter = TextPainter(
    text: spans,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  );
  if (marks.isNotEmpty) {
    painter.setPlaceholderDimensions([
      for (final _ in marks)
        PlaceholderDimensions(
          size: Size(side, side),
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
      (rect: boxes[i].toRect(), checked: marks[i].checked, line: marks[i].line),
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
