// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finger-following edge drags for the compact shell's two drawers.
///
/// The `Scaffold` drawer already tracks a drag from its first pixel, settles
/// open past half its width or on a fling, follows the finger back shut, and
/// fades its scrim with its position. What it cannot do is run at a window's
/// width alone: `DrawerController` turns both the open and the close drag off
/// whenever `Theme.of(context).platform` is a desktop family, so a desktop
/// window narrowed below `kCompactWidth` lost the gesture a phone of the same
/// width keeps (`desktop-vs-mobile.md`: width, never platform). An earlier
/// hand-rolled strip opened the drawer only after 80 pixels of travel and then
/// animated, which is the "does nothing until far enough" the owner reported.
///
/// [DrawerEdgeDrag] therefore leaves the framework drawer in charge and only
/// presents it a mobile platform on a desktop host. Every slot of the scaffold
/// must keep the real platform (scroll physics and the app bar's title
/// alignment read it), so the builder hands back [restore] to wrap each slot,
/// the drawers' content included; only the `DrawerController` above them sees
/// the mobile one.
library;

import 'package:flutter/material.dart';

import '../desktop/window_resize_frame.dart';

/// The band at each side edge where a horizontal drag means "pull the drawer".
///
/// Deliberately not wider than 24 past the system's own claim: a compact row
/// puts its avatar at x=10 through 46 (`paneGutterCompact` plus the avatar
/// size), so a wider zone would swallow most of it. A tap is never affected,
/// only a drag that starts here.
const double kDrawerEdgeZoneWidth = 24;

/// The drag width to hand `Scaffold.drawerEdgeDragWidth` at [context].
///
/// Past whichever of the system gesture inset (Android's back swipe claims
/// that band first) and the display padding (a landscape notch) is larger, so
/// the zone the app owns never sits entirely under the system's. A frameless
/// desktop window's own resize band (`window_resize_frame.dart`) sits on top of
/// the first few pixels and wins them, so the zone starts past it.
double drawerEdgeDragWidth(BuildContext context, {bool frameless = false}) {
  final gestures = MediaQuery.systemGestureInsetsOf(context);
  final padding = MediaQuery.paddingOf(context);
  final system = [
    gestures.left,
    gestures.right,
    padding.left,
    padding.right,
  ].reduce((a, b) => a > b ? a : b);
  final resizeBand = frameless ? kWindowResizeHandleThickness : 0.0;
  return system + resizeBand + kDrawerEdgeZoneWidth;
}

/// Wraps a compact `Scaffold` so its drawers drag at any platform.
class DrawerEdgeDrag extends StatelessWidget {
  const DrawerEdgeDrag({required this.builder, super.key});

  /// Builds the scaffold. [restore] wraps a slot in the theme as it was before
  /// this widget, and must be applied to every slot.
  final Widget Function(BuildContext context, Widget Function(Widget) restore)
  builder;

  static bool _isDesktop(TargetPlatform platform) => switch (platform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };

  @override
  Widget build(BuildContext context) {
    final original = Theme.of(context);
    if (!_isDesktop(original.platform)) return builder(context, (w) => w);
    return Theme(
      data: original.copyWith(platform: TargetPlatform.android),
      child: Builder(
        builder: (context) =>
            builder(context, (w) => Theme(data: original, child: w)),
      ),
    );
  }
}
