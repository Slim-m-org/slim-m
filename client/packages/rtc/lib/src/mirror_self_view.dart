// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a local camera preview is drawn mirrored, set once near the app's
/// root so every `CameraView` below follows it without the session needing a
/// setter on its interface.
library;

import 'package:flutter/widgets.dart';

/// Carries the "Mirror my view" choice. It only ever changes how this
/// device draws its own preview; what others receive is never mirrored.
class MirrorSelfViewScope extends InheritedWidget {
  const MirrorSelfViewScope({
    super.key,
    required this.mirror,
    required super.child,
  });

  final bool mirror;

  /// Mirrored when no scope is above, the long-standing default.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MirrorSelfViewScope>()
          ?.mirror ??
      true;

  @override
  bool updateShouldNotify(MirrorSelfViewScope oldWidget) =>
      mirror != oldWidget.mirror;
}
