// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this viewer sees the shared board or their own arrangement of it.
/// Decision 0082.
library;

import 'package:flutter/foundation.dart';

import 'canvas_document.dart';
import 'canvas_personal_layout.dart';
import 'canvas_presence_tile_overrides.dart';

/// The shared view fits the board and puts tiles where everyone agreed; the
/// personal view keeps the camera and the tile places this viewer chose, and
/// leaves what others see untouched.
class CanvasViewMode extends ChangeNotifier {
  CanvasViewMode({required this.document, required this.tiles});

  final CanvasDocument document;
  final CanvasPresenceTileOverrides tiles;

  Camera? _personalCamera;

  /// A restored camera waits here until the pane has a size to hold it to.
  Camera? _awaitingViewport;

  bool get personal => tiles.personal;

  /// What would be kept for this viewer if they left now.
  CanvasPersonalLayout get layout => CanvasPersonalLayout(
        personal: personal,
        camera: personal ? document.camera : _personalCamera,
        places: tiles.personalPlaces,
      );

  /// Whether there is anything of this viewer's own to reset.
  bool get hasLayout => !layout.isEmpty;

  void showPersonal() {
    if (personal) return;
    tiles.personal = true;
    final remembered = _personalCamera;
    if (remembered != null) document.setCamera(remembered);
    notifyListeners();
  }

  void showShared() {
    if (!personal) return;
    // An untouched fit camera is not an arrangement of this viewer's own.
    _personalCamera = document.isFitted ? null : document.camera;
    tiles.personal = false;
    document.fitBoard();
    notifyListeners();
  }

  void toggle() => personal ? showShared() : showPersonal();

  /// Drops this viewer's own camera and tile places and returns to the shared view.
  void reset() {
    _awaitingViewport = null;
    _personalCamera = null;
    tiles.clearPersonalPlaces();
    if (personal) {
      tiles.personal = false;
      document.fitBoard();
    }
    notifyListeners();
  }

  /// Takes back a kept layout, held to the board again on the way in.
  void restore(CanvasPersonalLayout kept) {
    tiles.restorePersonalPlaces(kept.places);
    _personalCamera = kept.camera;
    if (kept.personal) {
      tiles.personal = true;
      _applyWhenSized(kept.camera);
    }
    notifyListeners();
  }

  /// Takes back a kept layout beneath what this viewer has already done since
  /// the canvas opened: their own newer places and view are left as they are.
  void restoreBeneath(CanvasPersonalLayout kept) {
    final current = tiles.personalPlaces;
    tiles.restorePersonalPlaces({
      for (final e in kept.places.entries)
        if (!current.containsKey(e.key)) e.key: e.value,
    });
    _personalCamera ??= kept.camera;
    notifyListeners();
  }

  void _applyWhenSized(Camera? camera) {
    if (camera == null) return;
    if (!document.viewport.isEmpty) {
      document.setCamera(camera);
      return;
    }
    _awaitingViewport = camera;
    document.addListener(_onDocumentChanged);
  }

  void _onDocumentChanged() {
    final waiting = _awaitingViewport;
    if (waiting == null || document.viewport.isEmpty) return;
    _awaitingViewport = null;
    document.removeListener(_onDocumentChanged);
    if (personal) document.setCamera(waiting);
  }

  @override
  void dispose() {
    document.removeListener(_onDocumentChanged);
    super.dispose();
  }
}
