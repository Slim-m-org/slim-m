// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's own input around the board: its shortcuts, a press that
/// takes the keyboard back, the tool keys, and an image dropped to place it.
library;

import 'package:desktop_drop/desktop_drop.dart' show DropItem;
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/app_drop_zone.dart';

class CanvasPaneInput extends StatelessWidget {
  const CanvasPaneInput({
    super.key,
    required this.shortcuts,
    required this.focusNode,
    required this.onKey,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.canDrop,
    required this.onDrop,
    required this.child,
  });

  final Map<ShortcutActivator, VoidCallback> shortcuts;
  final FocusNode focusNode;
  final KeyEventResult Function(KeyEvent event) onKey;
  final PointerDownEventListener onPointerDown;

  /// Hears a cancel as well as a lift.
  final void Function(PointerEvent event) onPointerUp;
  final bool canDrop;
  final void Function(List<DropItem> items) onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: shortcuts,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: onPointerDown,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerUp,
      // Not a Tab stop of its own: the board is the labelled stop and holds focus; this hears what bubbles up.
      child: Focus(
        skipTraversal: true,
        focusNode: focusNode,
        onKeyEvent: (_, event) => onKey(event),
        child: AppDropZone(
          enabled: canDrop,
          label: 'Drop an image to place it',
          icon: AppIcons.image,
          onDrop: (items, _) => onDrop(items),
          child: child,
        ),
      ),
    ),
  );
}
