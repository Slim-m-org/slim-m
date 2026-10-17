// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The box a note is placed with: sized to its own text so a long note
/// simply fits, rather than a fixed box a long note quietly clips inside.
///
/// The font metrics here (12px, 1.3 line height, 8px padding, `AppFonts.sans`)
/// must match `_paintNote`'s own literals in `canvas_painters_shapes.dart` -
/// this is a prediction of what that painter will do, not a second opinion
/// about it, and the two would silently disagree if either changed alone.
library;

import 'package:flutter/painting.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show maxObjectExtent;

const double _noteFontSize = 12;
const double _noteLineHeight = 1.3;
const double _notePad = 8;

/// One line's own height, and a fudge factor past a whole extra one: the
/// painter's `noteMaxLines` (`canvas_painters_shapes.dart`) derives its own
/// line budget from this box's height by floor-dividing, and an engine text
/// layout is not bit-identical to the same arithmetic done twice, so a box
/// sized to the exact boundary can floor one line short and ellipsis the
/// note's own last line - reproduced directly against the real painter
/// function before this margin was added, not assumed.
const double _lineHeight = _noteFontSize * _noteLineHeight;
const double _lineBudgetMargin = _lineHeight * 1.5;

/// A note's box: fixed at [width] - a comfortable reading measure, not
/// something a long note should widen past - with [height] grown to fit
/// [text] wrapped at that width, never below [minHeight] so a short note
/// keeps the same box it always had, and never above [maxObjectExtent],
/// the one bound a note shares with every other canvas object.
({double width, double height}) noteBoxFor(
  String text, {
  double width = 220,
  double minHeight = 140,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: _noteFontSize,
        height: _noteLineHeight,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - _notePad * 2);
  final needed = painter.height + _notePad * 2 + _lineBudgetMargin;
  return (width: width, height: needed.clamp(minHeight, maxObjectExtent));
}
