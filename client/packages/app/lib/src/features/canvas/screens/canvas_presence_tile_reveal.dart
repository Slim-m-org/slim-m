// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pointer_gate.dart';

/// Hides [child] from pointers and sight until the tile is revealed. It stays
/// in the semantics tree so a screen reader keeps the controls, and focus
/// within it reveals them so a keyboard user never operates an unseen one.
class TileRevealGate extends StatelessWidget {
  const TileRevealGate({
    super.key,
    required this.shown,
    required this.room,
    required this.onFocusChange,
    required this.onKeyEvent,
    required this.child,
  });

  /// Whether the tile is revealed and the control has room to show.
  final bool shown;

  /// Whether the control fits on the tile at all.
  final bool room;
  final ValueChanged<bool> onFocusChange;
  final KeyEventResult Function(KeyEvent event) onKeyEvent;
  final Widget child;

  @override
  Widget build(BuildContext context) => CanvasPointerGate(
    ignoring: !shown,
    child: AnimatedOpacity(
      opacity: shown ? 1 : 0,
      duration: AppMotion.reduced(context, AppMotion.fast),
      alwaysIncludeSemantics: true,
      // A control with no room never shows, so keyboard focus must not land on it unseen.
      child: ExcludeFocus(
        excluding: !room,
        // The tile's own menu carries these actions, so a no-room control publishes no node over the tile.
        child: ExcludeSemantics(
          excluding: !room,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: onFocusChange,
            onKeyEvent: (_, event) => onKeyEvent(event),
            child: child,
          ),
        ),
      ),
    ),
  );
}
