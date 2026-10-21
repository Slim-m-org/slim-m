// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A one-pointer drag on empty board with the pan tool moves the camera, so a
/// phone pans with one finger and a mouse pans by dragging, not only with
/// two fingers or the wheel.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// How far, in screen pixels, a press may wander and still be a tap rather than a pan.
const double canvasDragPanSlopPx = 6;

class CanvasDragPan {
  Offset? _start;
  Offset? _anchor;

  bool get active => _start != null;

  /// Whether the press has travelled past the tap slop and is moving the camera.
  bool get moving => _anchor != null;

  /// Arms a pan from [world]; the camera stays put until the pointer leaves the tap slop.
  void begin(Offset world) {
    _start = world;
    _anchor = null;
  }

  /// [world] is the pointer's board point under the camera as it is now, so
  /// moving the camera by the difference puts the anchor back under it.
  void drag(Offset world, CanvasDocument document) {
    final start = _start;
    if (start == null) return;
    final camera = document.camera;
    final anchor = _anchor;
    if (anchor == null) {
      // Anchored where the slop is crossed, so the camera does not lurch by the slop.
      if ((world - start).distance * camera.zoom > canvasDragPanSlopPx) {
        _anchor = world;
      }
      return;
    }
    document.setCamera(
      camera.copyWith(
        x: camera.x + (anchor.dx - world.dx),
        y: camera.y + (anchor.dy - world.dy),
      ),
    );
  }

  void end() {
    _start = null;
    _anchor = null;
  }
}
