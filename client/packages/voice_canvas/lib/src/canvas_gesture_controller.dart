// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets code outside the surface abandon the stroke or shape the pointer is drawing right now.
library;

/// Held by the owner of a `CanvasSurface`; the surface attaches itself while mounted.
class CanvasGestureController {
  bool Function()? _cancel;

  /// Attaches the surface's handler; the surface calls this, nothing else should.
  void attach(bool Function()? cancel) => _cancel = cancel;

  /// Drops an in-progress stroke or shape without committing it; false when nothing was being drawn.
  bool cancelDrawing() => _cancel?.call() ?? false;
}
