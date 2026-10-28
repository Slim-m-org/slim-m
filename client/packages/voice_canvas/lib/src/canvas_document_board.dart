// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// The shared board's view of [CanvasDocument]: where it sits, whether the
/// whole of it is in view, and what may be placed on it. Decision 0073.
extension CanvasDocumentBoard on CanvasDocument {
  /// Fixes the shared board: the camera then never leaves it and opens on
  /// [sharedArea] (the whole board when omitted). Null lifts the constraint.
  void setBoard(ui.Rect? board, {ui.Rect? sharedArea}) {
    if (board == _board && sharedArea == _sharedArea) return;
    _board = board;
    _sharedArea = sharedArea;
    _atFit = true;
    _retrackAllOutside();
    _camera = board == null ? _clamp(_camera) : _sharedCamera(board);
    _reculled();
  }

  ui.Rect? get board => _board;

  /// The region every viewer frames in the shared view; null when no board is set.
  ui.Rect? get sharedArea => _board == null ? null : _sharedArea ?? _board;

  /// The zoom at which the shared area fills the view, 100% on the zoom pill; the board's floor when a tall pane cannot show it whole.
  double get sharedFitZoom {
    final shared = sharedArea;
    final board = _board;
    if (shared == null || board == null) return 1;
    return math.max(boardFitZoom(shared, _fitView), zoomFloor);
  }

  ui.Rect get _sharedRect => _sharedArea ?? _board!;

  Camera _sharedCamera(ui.Rect board) =>
      sharedAreaCamera(_sharedRect, board, _fitView);

  bool _isSharedCamera(Camera camera, ui.Rect board) {
    final shared = _sharedCamera(board);
    return (camera.zoom - shared.zoom).abs() <= 1e-9 &&
        (camera.x - shared.x).abs() <= 1e-6 &&
        (camera.y - shared.y).abs() <= 1e-6;
  }

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

  /// Whether the camera sits on the shared area, as opposed to a pan or zoom away from it.
  bool get isFitted => _board != null && _atFit;

  /// Brings the shared area back into view.
  void fitBoard() {
    final board = _board;
    if (board != null) setCamera(_sharedCamera(board));
  }

  /// The union of the parts of live objects that lie on the board, or null when none do.
  ui.Rect? get boardContentBounds {
    final board = _board;
    if (board == null) return contentBounds;
    ui.Rect? bounds;
    for (final stroke in _strokes) {
      if (stroke == null || !stroke.alive) continue;
      final box = ui.Rect.fromLTWH(stroke.x, stroke.y, stroke.w, stroke.h);
      if (!box.overlaps(board)) continue;
      final onBoard = box.intersect(board);
      bounds = bounds?.expandToInclude(onBoard) ?? onBoard;
    }
    return bounds;
  }

  /// Fits the camera to the drawn objects on the board above the dock; the whole board when none are.
  void fitContent() {
    final bounds = boardContentBounds;
    if (bounds == null || _viewport.isEmpty) return fitBoard();
    setCamera(cameraToFit(bounds, _fitView));
  }

  /// The part of the board in view, or null when no board is set; the shared area while fitted.
  ui.Rect? get visibleBoard {
    final board = _board;
    if (board == null) return null;
    return isFitted ? sharedArea : visibleBoardPart(worldView, board);
  }

  /// Shows [view] (a board rectangle) fitted to this viewport's own aspect.
  void showBoardView(ui.Rect view) {
    final board = _board;
    if (board != null) setCamera(cameraForBoardView(view, board, _fitView));
  }

  /// Fits [rect] (world units) to the viewport above the dock: aspect-fit, centred, held to the board when there is one.
  void showWorldRect(ui.Rect rect) {
    if (_viewport.isEmpty || rect.isEmpty) return;
    if (_board != null) return showBoardView(rect);
    setCamera(cameraToFit(rect, _fitView, padding: 0));
  }
}
