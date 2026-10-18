// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Comparisons of the view's reported size, split from desktop_window_shell.dart for its line budget.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show Size, WidgetsBinding;

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
/// Width only: a real launch reports a height that still carries a title bar, not the one asked for.
bool viewHasLeftSplash(Size? size) {
  if (size == null) return false;
  return (size.width - kSplashWindowSize.width).abs() > 1;
}

/// Waits, bounded, for the view to actually report the size the handoff
/// asked for ([target]), or with [fillsDisplay] to leave the splash's size.
///
/// This is what keeps the real UI from ever laying out at the splash's
/// size. `main.dart` flips `appReadyProvider` only after this returns, so
/// the first frame of the real app is built against the window it is
/// really in. Without it the flip races the compositor's own metrics, and
/// on a launch that loses the race the whole app builds at
/// [LayoutClass.compact] - a desktop window rendering the phone layout,
/// which the owner reported twice. Fails open on [timeout], because a
/// window whose metrics never arrive must still get its app.
Future<void> awaitViewAtHandoffSize({
  required WindowSize? target,
  required bool fillsDisplay,
  required Duration timeout,
}) async {
  if (target == null && !fillsDisplay) return;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final size = currentViewSize();
    final reached = target != null
        ? viewMatchesSize(size, target)
        : viewHasLeftSplash(size);
    if (reached) return;
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(_metricsPollStep);
    } catch (_) {
      // A frame that never came is not a reason to stop asking.
    }
  }
  debugPrint(
    'desktop: view never reported the handoff size $target; '
    'last seen ${currentViewSize()}',
  );
}

/// How long one poll waits for a frame before re-reading the view size: a
/// hidden or idle window can go a while without painting.
const _metricsPollStep = Duration(milliseconds: 100);

/// The implicit view's size in logical pixels, or null before it has one.
Size? currentViewSize() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return null;
  final ratio = view.devicePixelRatio;
  if (ratio <= 0) return null;
  return view.physicalSize / ratio;
}
