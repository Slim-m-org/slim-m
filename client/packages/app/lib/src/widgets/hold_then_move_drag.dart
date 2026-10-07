// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone rail's gesture: a held press opens the row's menu, and the row
/// only lifts once the held finger moves.
///
/// Flutter's delayed drag lifts the row the moment the hold registers, so a
/// press meant for the menu showed a drag first (owner backlog #218). Here the
/// hold claims the gesture, so the rail cannot turn it into a scroll, but the
/// drag waits for movement; a release without moving reports [onHeldInPlace]
/// instead. A move before the hold is still a scroll.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A reorder start listener that opens a menu on a still hold and drags on a held move.
class HoldThenMoveDragStartListener extends ReorderableDragStartListener {
  const HoldThenMoveDragStartListener({
    super.key,
    required super.child,
    required super.index,
    required this.onHeld,
    required this.onHeldInPlace,
  });

  /// The hold registered; feedback that a move now drags, or a release opens the menu.
  final VoidCallback onHeld;

  /// The finger came up after the hold without moving the row.
  final VoidCallback onHeldInPlace;

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      HoldThenMoveDragGestureRecognizer(
        debugOwner: this,
        onHeld: onHeld,
        onHeldInPlace: onHeldInPlace,
      );
}

class HoldThenMoveDragGestureRecognizer extends MultiDragGestureRecognizer {
  HoldThenMoveDragGestureRecognizer({
    super.debugOwner,
    required this.onHeld,
    required this.onHeldInPlace,
    this.delay = kLongPressTimeout,
  });

  final VoidCallback onHeld;
  final VoidCallback onHeldInPlace;
  final Duration delay;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _HoldThenMovePointerState(
        event.position,
        event.kind,
        gestureSettings,
        delay: delay,
        onHeld: onHeld,
        onHeldInPlace: onHeldInPlace,
      );

  @override
  String get debugDescription => 'hold then move multidrag';
}

class _HoldThenMovePointerState extends MultiDragPointerState {
  _HoldThenMovePointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings, {
    required Duration delay,
    required this.onHeld,
    required this.onHeldInPlace,
  }) {
    _timer = Timer(delay, _holdPassed);
  }

  final VoidCallback onHeld;
  final VoidCallback onHeldInPlace;
  Timer? _timer;
  GestureMultiDragStartCallback? _starter;
  bool _held = false;
  bool _dragged = false;

  void _holdPassed() {
    _timer = null;
    _held = true;
    resolve(GestureDisposition.accepted);
    onHeld();
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    // Holding the starter is what keeps the row down until the finger moves.
    _starter = starter;
  }

  @override
  void checkForResolutionAfterMove() {
    final moved =
        pendingDelta!.distance > computeHitSlop(kind, gestureSettings);
    if (!moved) return;
    if (!_held) {
      _timer?.cancel();
      _timer = null;
      resolve(GestureDisposition.rejected);
      return;
    }
    final starter = _starter;
    if (starter == null) return;
    _starter = null;
    _dragged = true;
    starter(initialPosition);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    final releasedInPlace = _held && !_dragged;
    super.dispose();
    if (releasedInPlace) onHeldInPlace();
  }
}
