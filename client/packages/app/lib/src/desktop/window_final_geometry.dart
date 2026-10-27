// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applying the saved-or-default window geometry once bootstrap has finished.
library;

import 'desktop_window_port.dart';
import 'window_geometry.dart';
import 'window_geometry_store.dart';

/// What the handoff reveal must wait for: a windowed size, or a display fill.
typedef HandoffTarget = ({WindowSize? size, bool fillsDisplay});

/// Hides the window, then applies the saved geometry while nothing is visible.
///
/// Size is clamped to the minimum before the display clamp so a saved size
/// below the floor is never restored where the OS minimum is not honored
/// (Wayland); see [clampSizeToMinimum].
Future<HandoffTarget> applyFinalGeometry(
  DesktopWindowPort port,
  WindowGeometryStore store, {
  required bool positionSupported,
}) async {
  await port.hide();

  final saved = store.read() ?? WindowGeometry.fallback;
  final sized = clampToAttachedDisplays(
    clampSizeToMinimum(saved),
    await port.allDisplays(),
  );
  final geometry = positionSupported
      ? sized
      : sized.copyWith(clearPosition: true);

  await port.setResizable(true);
  // After the splash, which is deliberately smaller than this floor.
  await port.setMinimumSize(WindowGeometry.minimumWindowSize);
  final position = geometry.position;
  if (position != null) {
    await port.setBounds(
      WindowRect(
        x: position.x,
        y: position.y,
        width: geometry.windowedSize.width,
        height: geometry.windowedSize.height,
      ),
    );
  } else {
    await port.setSize(geometry.windowedSize);
    await port.center();
  }

  switch (geometry.runState) {
    case WindowRunState.maximized:
      await port.maximize();
      return (size: null, fillsDisplay: true);
    case WindowRunState.fullscreen:
      await port.setFullScreen(true);
      return (size: null, fillsDisplay: true);
    case WindowRunState.windowed:
      return (size: geometry.windowedSize, fillsDisplay: false);
  }
}
