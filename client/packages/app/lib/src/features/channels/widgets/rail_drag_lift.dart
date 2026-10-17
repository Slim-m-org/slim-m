// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The feel of picking a channel row up and carrying it.
///
/// The owner's words: "add an on click and hold animation so it feels like
/// I'm grabbing it". Two moments make that feel. The press: the row settles
/// under the pointer the instant it goes down ([AppMotion.pressScale], the
/// same nudge every button here gives), so the hand knows it has hold of
/// something before it has moved. The lift: once the drag actually starts,
/// the carried copy rises a hair above the list on a raised surface with a
/// menu's shadow, and the list slides its neighbours around the gap. Both
/// collapse to a plain swap under reduce motion; the shadow stays, since it
/// is what says "this one is in the air" and moves nothing.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Wraps a row so pressing it reads as taking hold of it.
///
/// A raw [Listener], not a gesture recogniser: it must never enter the arena
/// the drag and the row's own tap are already contesting, it only watches.
class RailGrabFeedback extends StatefulWidget {
  const RailGrabFeedback({super.key, required this.child});

  final Widget child;

  @override
  State<RailGrabFeedback> createState() => _RailGrabFeedbackState();
}

class _RailGrabFeedbackState extends State<RailGrabFeedback> {
  bool _held = false;

  void _set(bool held) {
    // A lifted row's slot is rebuilt as a gap, so this can be told after it is gone.
    if (mounted && _held != held) setState(() => _held = held);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _held ? AppMotion.pressScale : 1,
        duration: AppMotion.reduced(context, AppMotion.fast),
        curve: AppMotion.entrance,
        child: widget.child,
      ),
    );
  }
}

/// The carried copy of a row while a reorder drag is in flight; the
/// `proxyDecorator` of the rail's [ReorderableListView].
class RailDragLift extends StatelessWidget {
  const RailDragLift({super.key, required this.animation, required this.child});

  /// The list's own lift animation: 0 at pick-up, 1 once fully carried.
  final Animation<double> animation;
  final Widget child;

  /// A hair above resting size, enough to read as lifted without the row
  /// looking enlarged.
  static const liftScale = 1.02;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final reduced = AppMotion.isReduced(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = AppMotion.entrance.transform(animation.value);
        return Transform.scale(
          scale: reduced ? 1 : 1 + (liftScale - 1) * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.accent),
              boxShadow: AppShadows.menu,
            ),
            child: child,
          ),
        );
      },
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
