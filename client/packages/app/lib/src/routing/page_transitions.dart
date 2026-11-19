// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Route transitions for the shell's own surfaces.
///
/// The settings and administration modals carry their own presentation in
/// `modal_page.dart`. This is the plainer case: one signed-in surface
/// replacing another inside the shell, which used to swap with no transition
/// at all - the "teleport" a real navigation should never read as.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import 'breakpoints.dart';

/// A page transition that matches its layout, collapsing to an instant swap
/// under reduce-motion.
///
/// At compact width this is the motion spec's drill-down: the destination
/// slides in full-width while the page beneath parallaxes 30% behind it, so
/// direction says where back goes, and popping reverses exactly. Where both
/// panes are visible there is no drill to express, so the pane cross-fades
/// and rises a hair instead.
///
/// [key] is what makes a channel switch animate at all: each destination is a
/// distinct page under its own key, so the framework animates the old one out
/// and the new one in rather than reusing a single page and rebuilding.
///
/// The wide branch is a genuine fade-through rather than a cross-fade, and
/// that distinction was a real bug: it faded the incoming pane in while the
/// outgoing one sat at full opacity underneath, so for the whole transition
/// two channels were legible at once and read as one drawn over the other.
/// The outgoing pane now clears over the first third before the incoming one
/// begins to arrive.
CustomTransitionPage<void> fadeThroughPage(
  BuildContext context,
  Widget child, {
  required LocalKey key,
}) {
  final duration = AppMotion.reduced(context, AppMotion.base);
  return CustomTransitionPage<void>(
    key: key,
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    transitionsBuilder: _fadeThroughTransition,
    child: child,
  );
}

/// A route pushed imperatively (`Navigator.push`) rather than through
/// go_router, presented with the same drill-down / fade-through language as
/// [fadeThroughPage]. The onboarding server-identity steps are the one place
/// that happens: a route pushed over another should behave the same way
/// everywhere, whichever API put it there.
PageRouteBuilder<T> fadeThroughRoute<T>(
  BuildContext context,
  WidgetBuilder builder,
) {
  final duration = AppMotion.reduced(context, AppMotion.base);
  return PageRouteBuilder<T>(
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: _fadeThroughTransition,
  );
}

Widget _fadeThroughTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) => _FadeThrough(
  animation: animation,
  secondaryAnimation: secondaryAnimation,
  child: child,
);

/// The transition itself, holding its curves for as long as the route shows.
///
/// A route rebuilds its transition on every frame it animates, so curves made
/// in the builder were three more listeners on the route's animations a frame.
class _FadeThrough extends StatefulWidget {
  const _FadeThrough({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_FadeThrough> createState() => _FadeThroughState();
}

class _FadeThroughState extends State<_FadeThrough> {
  late List<CurvedAnimation> _curves = _makeCurves();

  /// This page's own entrance, its underlay role, then the wide fade in and fade out.
  List<CurvedAnimation> _makeCurves() => [
    CurvedAnimation(
      parent: widget.animation,
      curve: AppMotion.entrance,
      reverseCurve: AppMotion.exit,
    ),
    CurvedAnimation(
      parent: widget.secondaryAnimation,
      curve: AppMotion.entrance,
      reverseCurve: AppMotion.exit,
    ),
    CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0.35, 1, curve: Curves.easeOut),
    ),
    CurvedAnimation(
      parent: widget.secondaryAnimation,
      curve: const Interval(0, 0.35, curve: Curves.easeIn),
    ),
  ];

  void _disposeCurves() {
    for (final curve in _curves) {
      curve.dispose();
    }
  }

  @override
  void didUpdateWidget(_FadeThrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation &&
        oldWidget.secondaryAnimation == widget.secondaryAnimation) {
      return;
    }
    _disposeCurves();
    _curves = _makeCurves();
  }

  @override
  void dispose() {
    _disposeCurves();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final [curved, curvedOut, incoming, outgoing] = _curves;
    if (LayoutClass.of(context) == LayoutClass.compact) {
      return SlideTransition(
        // This page's own entrance: in from the right edge.
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: SlideTransition(
          // And its underlay role: 30% left while the next page covers it.
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-0.3, 0),
          ).animate(curvedOut),
          // Opaque, or the page it slides over shows through its transparent text surface.
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: widget.child,
          ),
        ),
      );
    }
    // A fade-through, not a cross-fade: see fadeThroughPage's own doc.
    return FadeTransition(
      // Its underlay role: gone before whatever replaces it becomes legible.
      opacity: Tween<double>(begin: 1, end: 0).animate(outgoing),
      child: FadeTransition(
        opacity: incoming,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(curved),
          child: widget.child,
        ),
      ),
    );
  }
}
