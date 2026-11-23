// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applying the saved-or-default window geometry once bootstrap has finished.
library;

import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'desktop_window_port.dart';
import 'window_geometry.dart';
import 'window_geometry_store.dart';

/// What the handoff reveal must wait for: a windowed size, or a display fill.
typedef HandoffTarget = ({WindowSize? size, bool fillsDisplay});

/// Hides the window, then applies the saved geometry while nothing is visible.
///
/// [onTarget] fires before the maximize or fullscreen await, so a call that
/// hangs past the startup timeout still leaves the reveal its target.
///
/// Size is clamped to the minimum before the display clamp so a saved size
/// below the floor is never restored where the OS minimum is not honored
/// (Wayland); see [clampSizeToMinimum].
Future<void> applyFinalGeometry(
  DesktopWindowPort port,
  WindowGeometryStore store, {
  required bool positionSupported,
  required void Function(HandoffTarget target) onTarget,
}) async {
  await port.hide();

  final saved = store.read() ?? WindowGeometry.fallback;
  final displays = await port.allDisplays();
  final sized = clampToAttachedDisplays(clampSizeToMinimum(saved), displays);
  final geometry = positionSupported
      ? sized
      : sized.copyWith(clearPosition: true);
  AppLog.info(
    LogTag.platform,
    'Window geometry: saved ${_describe(saved)}, displays '
    '${displays.map((d) => '${d.x},${d.y} ${d.width}x${d.height}').join('; ')}, '
    'applying ${_describe(geometry)}',
  );

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
      onTarget((size: null, fillsDisplay: true));
      await port.maximize();
    case WindowRunState.fullscreen:
      onTarget((size: null, fillsDisplay: true));
      await port.setFullScreen(true);
    case WindowRunState.windowed:
      onTarget((size: geometry.windowedSize, fillsDisplay: false));
  }
}

String _describe(WindowGeometry geometry) {
  final position = geometry.position;
  final size = geometry.windowedSize;
  final at = position == null ? 'unplaced' : 'at ${position.x},${position.y}';
  return '${size.width}x${size.height} $at ${geometry.runState.name}';
}
