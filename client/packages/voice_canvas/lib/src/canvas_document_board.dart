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
    _retrackAllOutside();
    _camera = board == null ? _clamp(_camera) : boardFitCamera(board, _fitView);
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

  /// The box [id] may take for a requested [x], [y], [w], [h]: inside the
  /// board, a stroke only moved because its geometry cannot be resized.
  ({double x, double y, double w, double h}) boxOnBoard(
    String id,
    double x,
    double y,
    double w,
    double h,
  ) {
    final board = _board;
    if (board == null) return (x: x, y: y, w: w, h: h);
    final slot = _slotById[id];
    final isStroke =
        slot != null && _strokes[slot]?.kind == CanvasObjectKind.stroke;
    final fitted = fitBoxIntoBoard(
      ui.Rect.fromLTWH(x, y, w, h),
      board,
      shrink: !isStroke,
    );
    return (x: fitted.left, y: fitted.top, w: fitted.width, h: fitted.height);
  }

  /// [box] for a new object: pulled inside the board, shrunk if it is larger.
  ui.Rect placeOnBoard(ui.Rect box) {
    final board = _board;
    return board == null ? box : fitBoxIntoBoard(box, board);
  }

  /// Ids of live objects the board cannot hold whole, which its clip hides in
  /// part or in full. A stroke larger than the board is left out: no move
  /// could bring it in.
  List<String> get idsOutsideBoard => List.unmodifiable(_outsideIds);

  void _trackOutside(CanvasStroke? stroke) {
    if (stroke == null) return;
    final board = _board?.inflate(0.5);
    final outside = board != null &&
        stroke.alive &&
        !boardHoldsBox(
          board,
          ui.Rect.fromLTWH(stroke.x, stroke.y, stroke.w, stroke.h),
        ) &&
        (stroke.kind != CanvasObjectKind.stroke ||
            (stroke.w <= board.width && stroke.h <= board.height));
    final changed =
        outside ? _outsideIds.add(stroke.id) : _outsideIds.remove(stroke.id);
    if (changed) outsideBoardCount.value = _outsideIds.length;
  }

  void _retrackAllOutside() {
    _outsideIds.clear();
    _strokes.forEach(_trackOutside);
    outsideBoardCount.value = _outsideIds.length;
  }

  /// Whether the whole board is in view, as opposed to a temporary zoom.
  bool get isFitted => _board != null && _atFit;

  /// Brings the whole board back into view.
  void fitBoard() {
    final board = _board;
    if (board != null) setCamera(boardFitCamera(board, _fitView));
  }

  /// The part of the board in view, or null when no board is set.
  ui.Rect? get visibleBoard {
    final board = _board;
    return board == null ? null : visibleBoardPart(worldView, board);
  }

  /// Shows [view] (a board rectangle) fitted to this viewport's own aspect.
  void showBoardView(ui.Rect view) {
    final board = _board;
    if (board != null) setCamera(cameraForBoardView(view, board, _fitView));
  }
}
