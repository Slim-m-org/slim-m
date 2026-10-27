// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Small value types the scene ops share: a box, a gradient and a note.
library;

/// A box in scene units: where an op that is not naturally a rectangle sits.
///
/// Only [CellsOp] takes one so far. It is a type rather than four loose fields
/// because the four are meaningless apart - a width with no height describes
/// nothing - and because "absent" has to be one answer rather than four.
class SceneBox {
  const SceneBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final double x;
  final double y;
  final double w;
  final double h;
}

/// A two-stop linear gradient, for a `rect` or `circle`'s fill.
///
/// Its own type rather than three more keys on each op: a gradient is one
/// choice with three parts, and an op carrying `grad_from`, `grad_to` and
/// `grad_dir` separately can express two thirds of one, which is a state the
/// painter would have to invent an answer for.
///
/// Two stops only. A module that needs a third can draw two shapes, and every
/// extra stop is another list the parser has to bound.
class SceneGradient {
  const SceneGradient({
    required this.from,
    required this.to,
    this.direction = 'v',
  });

  /// Colour names, resolved the same way any other op's are: a theme token or
  /// a `#hex`.
  final String from;
  final String to;

  /// `v` top to bottom, `h` left to right, `d` diagonally. Anything else is
  /// read as `v`, the same "skip what is bad" treatment a malformed colour
  /// already gets, because a gradient that refused to draw would take the
  /// whole shape with it.
  final String direction;
}

/// One note: a frequency to ring, when it starts relative to the scene's own
/// age in seconds, and how long it rings. The same three numbers
/// `assets/audio/synth.py`'s `Note` carries, minus `gain` - a module states
/// none, so it cannot ask for a louder note than the app's own chimes ever
/// play. See [NotesOp] for the ceilings already applied by the time one of
/// these exists.
class SceneNote {
  const SceneNote({
    required this.frequency,
    required this.start,
    required this.seconds,
  });

  final double frequency;
  final double start;
  final double seconds;
}
