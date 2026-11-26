// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A touch or pen held still on the board.
///
/// A timer rather than a long-press recognizer: a recognizer joins the gesture arena, and one held finger would then reject the surface's pinch, or fire for a mouse.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';

class CanvasTouchHold {
  CanvasTouchHold({required this.onHold});

  /// Runs with the held point in local and global coordinates once the hold times out.
  final void Function(Offset local, Offset global) onHold;

  final Set<int> _down = {};
  Timer? _timer;
  int? _pointer;
  Offset _local = Offset.zero;
  Offset _global = Offset.zero;

  void down(PointerDownEvent event) {
    _down.add(event.pointer);
    cancel();
    final touchLike =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
    if (_down.length != 1 || !touchLike) return;
    _pointer = event.pointer;
    _local = event.localPosition;
    _global = event.position;
    _timer = Timer(kLongPressTimeout, () {
      _timer = null;
      onHold(_local, _global);
    });
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.localPosition - _local).distance > kTouchSlop) cancel();
  }

  void end(PointerEvent event) {
    _down.remove(event.pointer);
    if (event.pointer == _pointer) cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
  }
}
