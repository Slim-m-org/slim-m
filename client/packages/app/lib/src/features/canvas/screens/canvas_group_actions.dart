// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the context menu may do to objects picked together, handed down from the pane the way the lock state is.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasGroupActions {
  const CanvasGroupActions({
    required this.onAlign,
    required this.onDelete,
    required this.mayDelete,
  });

  final ValueChanged<CanvasAlign> onAlign;
  final VoidCallback onDelete;

  /// Whether anything in the group can be deleted by this person.
  final bool Function() mayDelete;
}

class CanvasGroupActionsScope extends InheritedWidget {
  const CanvasGroupActionsScope({
    super.key,
    required this.actions,
    required super.child,
  });

  final CanvasGroupActions actions;

  static CanvasGroupActions? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CanvasGroupActionsScope>()?.actions;

  @override
  bool updateShouldNotify(CanvasGroupActionsScope old) => false;
}
