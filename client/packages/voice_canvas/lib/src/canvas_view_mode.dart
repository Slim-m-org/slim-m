// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this viewer sees the shared board or their own arrangement of it.
/// Decision 0082.
library;

import 'package:flutter/foundation.dart';

import 'canvas_document.dart';
import 'canvas_presence_tile_overrides.dart';

/// The shared view fits the board and puts tiles where everyone agreed; the
/// personal view keeps the camera and the tile places this viewer chose, and
/// leaves what others see untouched.
class CanvasViewMode extends ChangeNotifier {
  CanvasViewMode({required this.document, required this.tiles});

  final CanvasDocument document;
  final CanvasPresenceTileOverrides tiles;

  Camera? _personalCamera;

  bool get personal => tiles.personal;

  void showPersonal() {
    if (personal) return;
    tiles.personal = true;
    final remembered = _personalCamera;
    if (remembered != null) document.setCamera(remembered);
    notifyListeners();
  }

  void showShared() {
    if (!personal) return;
    _personalCamera = document.camera;
    tiles.personal = false;
    document.fitBoard();
    notifyListeners();
  }

  void toggle() => personal ? showShared() : showPersonal();
}
