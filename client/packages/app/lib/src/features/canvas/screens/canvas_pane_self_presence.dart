// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_pane.dart';

/// The caller's own "never show my own camera" toggle: split out once
/// wiring it pushed `canvas_pane.dart` past the 500-line hard limit, the
/// same reason `canvas_pane_gestures.dart`'s own doc names. Position, size,
/// lock and hide for every other tile go straight through `_tileOverrides`
/// with no callback of their own to wire here - `CanvasPresenceLayer` reads
/// and writes it directly.
extension _CanvasPaneSelfPresence on _CanvasPaneState {
  /// Reads the current value fresh rather than closing over whatever
  /// `build()` last saw, so two fast taps land as a toggle rather than both
  /// racing to set the identical value.
  void _onToggleSelfBubbleHidden() => unawaited(
    ref
        .read(canvasSelfPresenceProvider.notifier)
        .setHidden(!ref.read(canvasSelfPresenceProvider).hidden),
  );
}
