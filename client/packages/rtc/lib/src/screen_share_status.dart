// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why a screen share tile has no picture, and the seam that lets the app draw
/// that reason with its own widgets: this package takes no design_system dependency.
library;

import 'package:flutter/widgets.dart';

enum ScreenShareStatus {
  /// The share is announced but its track or first frame has not arrived.
  loading,

  /// The track is coming back after this tile had already shown a picture.
  resuming,

  /// The sharer paused it: the publication is muted.
  paused,

  /// The publication went away after being seen.
  ended,
}

typedef ScreenShareStatusBuilder = Widget Function(
    BuildContext context, ScreenShareStatus status);

/// Supplies the placeholder every [ScreenShareStatus] is drawn with below it.
class ScreenShareStatusScope extends InheritedWidget {
  const ScreenShareStatusScope({
    super.key,
    required this.builder,
    required super.child,
  });

  final ScreenShareStatusBuilder builder;

  /// Null when no scope is above, which keeps the plain loading dots.
  static ScreenShareStatusBuilder? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ScreenShareStatusScope>()
      ?.builder;

  @override
  bool updateShouldNotify(ScreenShareStatusScope oldWidget) =>
      builder != oldWidget.builder;
}
