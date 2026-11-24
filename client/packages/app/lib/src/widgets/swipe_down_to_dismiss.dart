// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tracked vertical drag that dismisses whatever it wraps: [child] follows
/// the finger via [Transform.translate] as it moves, and either commits to
/// [onDismiss] or snaps back to place on release, the same shape
/// `fullscreen_image_viewer.dart`'s own dismiss drag already uses for a
/// photo. Its own widget, not copied a second time into
/// `attachment_video_fullscreen.dart`, so a test can drive the gesture
/// against a plain child rather than a real video texture.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class SwipeDownToDismiss extends StatefulWidget {
  const SwipeDownToDismiss({
    super.key,
    required this.enabled,
    required this.onDismiss,
    required this.child,
    this.dismissDistance = 96,
    this.dismissVelocity = 700,
  });

  /// Per `desktop-vs-mobile.md`'s core rule, callers gate this on capability
  /// and width rather than platform - false leaves the drag inert so a
  /// pointer drag on a wide window falls through to whatever is beneath it.
  final bool enabled;

  final VoidCallback onDismiss;
  final Widget child;

  /// How far a drag must travel before release counts as a dismiss.
  final double dismissDistance;

  /// A fast flick commits even short of [dismissDistance].
  final double dismissVelocity;

  @override
  State<SwipeDownToDismiss> createState() => _SwipeDownToDismissState();
}

class _SwipeDownToDismissState extends State<SwipeDownToDismiss> {
  double _dragged = 0;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() => _dragged = math.max(0, _dragged + details.delta.dy));
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final committed =
        _dragged >= widget.dismissDistance ||
        velocity >= widget.dismissVelocity;
    if (committed) {
      widget.onDismiss();
      return;
    }
    setState(() => _dragged = 0);
  }

  void _onDragCancel() => setState(() => _dragged = 0);

  @override
  void didUpdateWidget(SwipeDownToDismiss oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _dragged != 0) _dragged = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: widget.enabled ? _onDragUpdate : null,
      onVerticalDragEnd: widget.enabled ? _onDragEnd : null,
      onVerticalDragCancel: widget.enabled ? _onDragCancel : null,
      child: Transform.translate(
        offset: Offset(0, _dragged),
        child: widget.child,
      ),
    );
  }
}
