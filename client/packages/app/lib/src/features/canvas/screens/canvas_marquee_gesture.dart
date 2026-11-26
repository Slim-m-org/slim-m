// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The drag box: pressing empty board and dragging picks every object the box touches.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_drag_pan.dart';

class CanvasMarqueeGesture {
  CanvasMarqueeGesture(this._document, {required this.accepts});

  final CanvasDocument _document;

  /// Whether this person may pick [id]: not locked, and theirs or any with MANAGE_CANVAS.
  final bool Function(String id) accepts;

  Offset? _start;
  Set<String> _kept = const {};
  bool _open = false;

  /// Whether a press is armed to draw a box.
  bool get armed => _start != null;

  /// Arms a box from [world]; [additive] keeps what was already picked and adds to it.
  void begin(Offset world, {required bool additive}) {
    _start = world;
    _open = false;
    _kept = additive ? {..._document.multiSelection.all} : const {};
  }

  void drag(Offset world) {
    final start = _start;
    if (start == null) return;
    final zoom = _document.camera.zoom;
    if (!_open && (world - start).distance * zoom <= canvasDragPanSlopPx) {
      return;
    }
    _open = true;
    final box = Rect.fromPoints(start, world);
    final picked = objectIdsInRect(_document, box, accepts: accepts);
    _document.multiSelection
      ..marquee.value = box
      ..select({..._kept, ...picked});
  }

  void end() {
    _start = null;
    _open = false;
    _document.multiSelection.marquee.value = null;
  }
}
