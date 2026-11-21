// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The entrance and exit every bare-`OverlayPortal` menu was missing.
///
/// Everything routed through `showAppSheet`/`showGeneralDialog` animates both
/// directions, while the overlays driven by a raw [OverlayPortalController] -
/// the context menu, the reaction picker, the Space menu - appeared and
/// vanished in one frame, because `hide()` unmounts the overlay child
/// immediately and leaves nothing on screen to animate.
///
/// [AnimatedMenuController] closes that structurally rather than per call
/// site: it wraps the portal controller, and its own `hide()` first plays the
/// mounted [AnimatedMenuSurface]'s exit in reverse, releasing the portal only
/// once that lands - so the exit is real, not just the entrance. The surface
/// itself is the one authored look, `member_profile.dart`'s popover pattern
/// as a scale-from-the-anchor: a fade plus a 0.96-to-1 scale on
/// [AppMotion.fast], entrance curve forward, exit curve in reverse, and both
/// collapsing to nothing under reduce-motion via [AppMotion.reduced].
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// An [OverlayPortalController] whose `hide()` exits before it unmounts.
///
/// Drop-in for the raw controller: `show`/`hide`/`toggle`/`isShowing` keep
/// their shapes, and the overlay child wraps itself in an
/// [AnimatedMenuSurface] naming this controller. A `hide()` with no surface
/// mounted (or one already gone) falls back to hiding immediately, so a
/// caller never strands an overlay by hiding at an odd moment.
class AnimatedMenuController {
  final OverlayPortalController _portal = OverlayPortalController();

  /// Hand this to the [OverlayPortal] and nothing else: showing or hiding
  /// through it directly skips the exit this class exists to play.
  OverlayPortalController get portal => _portal;

  AnimatedMenuSurfaceState? _surface;

  /// True from `show()` until the exit finishes and the portal releases, the
  /// same window the raw controller reports.
  bool get isShowing => _portal.isShowing;

  void show() {
    if (!_portal.isShowing) {
      _portal.show();
      return;
    }
    // Reopened mid-exit: the surface is still mounted, so re-enter in place.
    _surface?.enter();
  }

  void hide() {
    final surface = _surface;
    if (surface == null) {
      if (_portal.isShowing) _portal.hide();
      return;
    }
    surface.exit();
  }

  void toggle() => isShowing ? hide() : show();

  void _release() {
    if (_portal.isShowing) _portal.hide();
  }
}

/// The animated body an [AnimatedMenuController]'s overlay child mounts:
/// plays the entrance on mount and registers itself so the controller's
/// `hide()` can play the exit before releasing the portal.
///
/// [alignment] is the scale's origin and should sit where the menu meets its
/// anchor - top-left for a menu opening under a pointer, top-right for one
/// hanging off a right-aligned button - so growth reads as coming from the
/// thing that opened it.
class AnimatedMenuSurface extends StatefulWidget {
  const AnimatedMenuSurface({
    super.key,
    required this.controller,
    required this.child,
    this.alignment = Alignment.topLeft,
  });

  final AnimatedMenuController controller;
  final Widget child;
  final Alignment alignment;

  @override
  State<AnimatedMenuSurface> createState() => AnimatedMenuSurfaceState();
}

/// Public only so [AnimatedMenuController] can name it; not for callers.
class AnimatedMenuSurfaceState extends State<AnimatedMenuSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _t,
    curve: AppMotion.entrance,
    reverseCurve: AppMotion.exit,
  );

  /// An exiting menu is already closed as far as input goes: it must not eat
  /// the tap or scroll that dismissed it while its fade-out finishes.
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    widget.controller._surface = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _t.duration = AppMotion.reduced(context, AppMotion.fast);
    if (_t.value == 0 && !_t.isAnimating) _t.forward();
  }

  @override
  void dispose() {
    if (identical(widget.controller._surface, this)) {
      widget.controller._surface = null;
    }
    _curved.dispose();
    _t.dispose();
    super.dispose();
  }

  void enter() {
    if (_exiting) setState(() => _exiting = false);
    _t.forward();
  }

  void exit() {
    if (!_exiting) setState(() => _exiting = true);
    _t.reverse().whenComplete(() {
      // A re-show mid-exit retargets forward; only a finished exit releases.
      if (_t.value == 0 && mounted) widget.controller._release();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: IgnorePointer(
        ignoring: _exiting,
        child: ScaleTransition(
          scale: _curved.drive(Tween(begin: 0.96, end: 1)),
          alignment: widget.alignment,
          child: widget.child,
        ),
      ),
    );
  }
}
