// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Comparisons of the view's reported size, split from desktop_window_shell.dart for its line budget.
library;

import 'package:flutter/widgets.dart' show Size;

import 'window_geometry.dart';

/// Whether [size] is the window [target] asked for, to within a logical
/// pixel either way.
///
/// Rounded rather than exact: a compositor converts through physical pixels
/// and a fractional device pixel ratio, so a window that is exactly right
/// can still report 1279.9998. An exact comparison would wait out the whole
/// timeout on every fractional-scale display.
bool viewMatchesSize(Size? size, WindowSize target) {
  if (size == null) return false;
  return (size.width - target.width).abs() <= 1 &&
      (size.height - target.height).abs() <= 1;
}

/// Whether the view reports a size other than the splash's own, the only
/// signal a maximized or fullscreen handoff has that the compositor resized.
/// Width only: the height a real launch reports (507) is not the 460 asked for.
bool viewHasLeftSplash(Size? size) {
  if (size == null) return false;
  return (size.width - kSplashWindowSize.width).abs() > 1;
}
