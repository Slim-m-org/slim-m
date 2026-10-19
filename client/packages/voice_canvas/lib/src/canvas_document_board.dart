// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The shared board's view of [CanvasDocument]: where it sits, whether the
/// whole of it is in view, and what may be placed on it. Decision 0073.
extension CanvasDocumentBoard on CanvasDocument {
  /// Fixes the shared board: the camera then never leaves it and opens fitted.
  /// Null lifts the constraint.
  void setBoard(ui.Rect? board) {
    if (board == _board) return;
    _board = board;
    _atFit = true;
    _camera =
        board == null ? _clamp(_camera) : boardFitCamera(board, _viewport);
    _reculled();
  }

  ui.Rect? get board => _board;

  /// Whether [world] may start a new mark: always without a board, else inside it.
  bool acceptsPlacementAt(ui.Offset world) =>
      _board == null || _board!.contains(world);

  /// [world] pulled inside the board, so ink dragged past its edge stays on it.
  ui.Offset clampToBoard(ui.Offset world) {
    final board = _board;
    if (board == null) return world;
    return ui.Offset(
      world.dx.clamp(board.left, board.right).toDouble(),
      world.dy.clamp(board.top, board.bottom).toDouble(),
    );
  }

  /// Whether the whole board is in view, as opposed to a temporary zoom.
  bool get isFitted => _board != null && _atFit;

  /// Brings the whole board back into view.
  void fitBoard() {
    final board = _board;
    if (board != null) setCamera(boardFitCamera(board, _viewport));
  }

  /// The part of the board in view, or null when no board is set.
  ui.Rect? get visibleBoard {
    final board = _board;
    return board == null ? null : visibleBoardPart(worldView, board);
  }

  /// Shows [view] (a board rectangle) fitted to this viewport's own aspect.
  void showBoardView(ui.Rect view) {
    final board = _board;
    if (board != null) setCamera(cameraForBoardView(view, board, _viewport));
  }
}
