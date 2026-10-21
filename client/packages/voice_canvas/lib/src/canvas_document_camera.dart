// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The camera and viewport of [CanvasDocument], clamped to the world or the board.
extension CanvasDocumentCamera on CanvasDocument {
  /// Moves the camera, clamped so the view stays inside the bounded world and
  /// the zoom inside the range a viewport read is sized for.
  ///
  /// Silent when the clamp lands on the camera already held, the same guard
  /// [setViewport] keeps and for a sharper reason. This is called once per
  /// pointer event for the whole of a pan or a pinch, and a gesture that runs
  /// into a world edge or a zoom stop keeps resolving to the held camera for
  /// as long as the finger stays down. Every notification from here rebuilds
  /// both presence layers, so those are whole rebuilds of a frame that has
  /// not changed.
  void setCamera(Camera next) {
    final clamped = _clamp(next);
    final board = _board;
    worldEdgeHit.value =
        board == null && (clamped.x != next.x || clamped.y != next.y);
    if (board != null && !_viewport.isEmpty) {
      _atFit = clamped.zoom <= boardFitZoom(board, _fitView) + 1e-9;
    }
    if (clamped == _camera) return;
    _camera = clamped;
    _reculled();
  }

  void setViewport(Size size) {
    if (size == _viewport) return;
    _viewport = size;
    final board = _board;
    _camera = board != null && _atFit
        ? boardFitCamera(board, _fitView)
        : _clamp(_camera);
    if (board != null && !size.isEmpty) {
      _atFit = _camera.zoom <= boardFitZoom(board, _fitView) + 1e-9;
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
