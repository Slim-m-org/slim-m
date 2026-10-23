// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The camera and viewport of [CanvasDocument], clamped to the world or the board.
extension CanvasDocumentCamera on CanvasDocument {
  /// Moves the camera, clamped to the bounded world and the zoom range a viewport read is sized for.
  /// Silent when the clamp lands on the held camera: this runs per pointer event and a gesture against a world edge would otherwise rebuild both presence layers for an unchanged frame.
  void setCamera(Camera next) {
    final clamped = _clamp(next);
    final board = _board;
    worldEdgeHit.value =
        board == null && (clamped.x != next.x || clamped.y != next.y);
    if (board != null && !_viewport.isEmpty) {
      _atFit = _isSharedCamera(clamped, board);
    }
    if (clamped == _camera) return;
    _camera = clamped;
    _reculled();
  }

  void setViewport(Size size) {
    if (size == _viewport) return;
    _viewport = size;
    final board = _board;
    _camera = board != null && _atFit ? _sharedCamera(board) : _clamp(_camera);
    if (board != null && !size.isEmpty) {
      _atFit = _isSharedCamera(_camera, board);
    }
    _reculled();
  }

  /// The world rectangle currently on screen.
  Rect get worldView => Rect.fromLTWH(
        _camera.x,
        _camera.y,
        _viewport.width / _camera.zoom,
        _viewport.height / _camera.zoom,
      );

  Camera _clamp(Camera next) {
    final board = _board;
    if (board != null) return clampCameraToBoard(next, board, _fitView);
    final zoom = next.zoom.clamp(minZoom, maxZoom);
    final w = _viewport.width / zoom;
    final h = _viewport.height / zoom;
    final maxX = math.max(-worldLimit, worldLimit - w);
    final maxY = math.max(-worldLimit, worldLimit - h);
    return Camera(
      x: next.x.clamp(-worldLimit, maxX),
      y: next.y.clamp(-worldLimit, maxY),
      zoom: zoom,
    );
  }
}
