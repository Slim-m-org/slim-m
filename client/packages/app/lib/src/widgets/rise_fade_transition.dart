// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The authored entrance of a modal, a popover and the command palette: a
/// curved fade with a short rise.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// Fades [child] in along [animation] while it rises [rise] pixels.
///
/// A widget with state, not a function a route's transition builder calls:
/// the builder runs on every frame of the transition, and a curve made there
/// is one more listener left on the route's animation each frame.
class RiseFadeTransition extends StatefulWidget {
  const RiseFadeTransition({
    super.key,
    required this.animation,
    required this.rise,
    required this.child,
  });

  final Animation<double> animation;
  final double rise;
  final Widget child;

  @override
  State<RiseFadeTransition> createState() => _RiseFadeTransitionState();
}

class _RiseFadeTransitionState extends State<RiseFadeTransition> {
  late CurvedAnimation _curved = _curve();

  CurvedAnimation _curve() => CurvedAnimation(
    parent: widget.animation,
    curve: AppMotion.entrance,
    reverseCurve: AppMotion.exit,
  );

  @override
  void didUpdateWidget(RiseFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation) return;
    _curved.dispose();
    _curved = _curve();
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curved,
    child: AnimatedBuilder(
      animation: _curved,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (1 - _curved.value) * widget.rise),
        child: child,
      ),
      child: widget.child,
    ),
  );
}
