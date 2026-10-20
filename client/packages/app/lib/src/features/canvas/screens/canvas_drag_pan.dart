// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A one-pointer drag on empty board with the pan tool moves the camera, so a
/// phone pans with one finger and a mouse pans by dragging, not only with
/// two fingers or the wheel.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

class CanvasDragPan {
  Offset? _anchor;

  bool get active => _anchor != null;

  /// Starts panning from [world], the board point that stays under the pointer.
  void begin(Offset world) => _anchor = world;

  /// [world] is the pointer's board point under the camera as it is now, so
  /// moving the camera by the difference puts [begin]'s point back under it.
  void drag(Offset world, CanvasDocument document) {
    final anchor = _anchor;
    if (anchor == null) return;
    final camera = document.camera;
    document.setCamera(
      camera.copyWith(
        x: camera.x + (anchor.dx - world.dx),
        y: camera.y + (anchor.dy - world.dy),
      ),
    );
  }

  void end() => _anchor = null;
}
