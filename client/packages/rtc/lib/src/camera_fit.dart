// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a camera feed fills the box its surface gives it, chosen per surface
/// by a scope so the session interface that builds the view stays unchanged.
library;

import 'package:flutter/widgets.dart';

/// Which part of a feed a surface shows.
enum CameraFit {
  /// Fills the box and crops the overflow; right for a bubble or a tile.
  cover,

  /// Shows the whole feed with bars where its shape differs from the box.
  contain,

  /// [cover] for a landscape or square feed, [contain] for a portrait one,
  /// so a phone held upright is not cropped to a strip of its height.
  coverUnlessPortrait,
}

/// Whether [fit] letterboxes a feed whose displayed [aspectRatio] is width over height.
bool fitShowsWholeFeed(CameraFit fit, double aspectRatio) => switch (fit) {
      CameraFit.cover => false,
      CameraFit.contain => true,
      CameraFit.coverUnlessPortrait => aspectRatio < 1,
    };

/// Carries the fit every `CameraView` below draws with.
class CameraFitScope extends InheritedWidget {
  const CameraFitScope({super.key, required this.fit, required super.child});

  final CameraFit fit;

  /// [CameraFit.cover] when no scope is above, the long-standing default.
  static CameraFit of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CameraFitScope>()?.fit ??
      CameraFit.cover;

  @override
  bool updateShouldNotify(CameraFitScope oldWidget) => fit != oldWidget.fit;
}
