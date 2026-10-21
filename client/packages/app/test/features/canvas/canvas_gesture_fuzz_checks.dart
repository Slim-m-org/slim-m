// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_gesture_fuzz_driver.dart';

/// The invariants, checked after every step and whenever all pointers are up.
extension _FuzzChecks on CanvasGestureFuzz {
  // Invariants ---------------------------------------------------------------

  void _stepInvariants() {
    final camera = _doc.camera;
    final viewport = _doc.viewport;
    if (!camera.x.isFinite || !camera.y.isFinite || !camera.zoom.isFinite) {
      _fail('camera-finite', 'camera is $camera');
      return;
    }
    if (!viewport.isEmpty) {
      final board = _doc.board;
      final fit = board == null ? minZoom : boardFitZoom(board, viewport);
      if (camera.zoom < fit - 1e-6 || camera.zoom > maxZoom + 1e-6) {
        _fail('camera-zoom', 'zoom ${camera.zoom} outside [$fit, $maxZoom]');
      }
      if (board != null) _boardContainment(board, camera, viewport);
    }
    final selected = _doc.selectedObjectId.value;
    if (selected != null) _server.absorbSent();
    if (selected != null && !_doc.isAlive(selected)) {
      _fail('selection-live', 'selected $selected is not a live object');
    }
    if (selected != null && _server.hiddenIds.contains(selected)) {
      _fail(
        'hidden-object-selected',
        '$selected lies outside the board, hidden by its clip, yet is selected',
      );
    }
  }

  void _boardContainment(Rect board, Camera camera, Size viewport) {
    final view = _doc.worldView;
    const eps = 1e-3;
    final fitsX = board.width * camera.zoom <= viewport.width + eps;
    final fitsY = board.height * camera.zoom <= viewport.height + eps;
    final xOk = fitsX
        ? (view.center.dx - board.center.dx).abs() < 1
        : view.left >= board.left - eps && view.right <= board.right + eps;
    final yOk = fitsY
        ? (view.center.dy - board.center.dy).abs() < 1
        : view.top >= board.top - eps && view.bottom <= board.bottom + eps;
    if (!xOk || !yOk) {
      _fail('camera-board', 'view $view leaves the board $board at $camera');
    }
  }

  Future<void> _segmentEnded() async {
    _segActive = false;
    await _tester.pump(const Duration(milliseconds: 300));
    await _tester.pump(const Duration(milliseconds: 300));
    _idleInvariants();
  }

  void _idleInvariants() {
    _server.absorbSent();
    for (final line in _server.divergences()) {
      _fail('pane-server-diverged', line);
      // ignore: avoid_print
      print(
        'DEBUG ops: ${rig.fixture.postedOps.map((o) => '${o['kind']}:${o['object_id'] ?? o['object_ids']}@${o['x']},${o['y']}').toList()}',
      );
    }
    for (final painter in rig.surfacePainters()) {
      final name = painter.runtimeType.toString();
      if (name == 'DraftPainter' &&
          !((painter as dynamic).draft.isEmpty as bool)) {
        _fail(
          'stuck-draft-stroke',
          'a pen draft is still painted with no pointer down',
        );
      }
      if (name == 'DraftShapePainter' &&
          (painter as dynamic).draft.rect != null) {
        _fail(
          'stuck-draft-shape',
          'a shape preview is still painted with no pointer down',
        );
      }
    }
    if (_server.touchedHidden.isNotEmpty) {
      _fail(
        'hidden-object-edited',
        'a gesture on the board sent an op for ${_server.touchedHidden}, which lie outside it',
      );
    }
    _tilesStayOnBoard();
    if (find.byType(AppErrorState).evaluate().isNotEmpty) {
      _fail(
        'error-banner',
        'the pane shows an error banner though the server accepted every request: ${_bannerText()}',
      );
    }
    _unbalanced('stroke-preview', rig.frames.strokePreviews);
    _unbalanced('object-preview', rig.frames.objectPreviews);
    if (_doc.externalPointers.count != 0) {
      _fail('external-pointers', 'count is ${_doc.externalPointers.count}');
    }
    if (_doc.elevatedObjectId.value != null) {
      _fail(
        'stuck-elevation',
        'object ${_doc.elevatedObjectId.value} is still lifted',
      );
    }
    if (_doc.snapGuides.value.isNotEmpty) {
      _fail('stuck-snap-guides', 'snap guides are still drawn');
    }
    final grabbing = _tester
        .widgetList<MouseRegion>(
          find.descendant(
            of: find.byType(CanvasSurface),
            matching: find.byType(MouseRegion),
          ),
        )
        .any((r) => r.cursor == SystemMouseCursors.grabbing);
    if (grabbing) {
      _fail('stuck-pan', 'the surface still shows the grabbing cursor');
    }
    if (!_segPrimary && !_segImpure) {
      final placed = rig.fixture.posted.length - _segPosted;
      final ops = rig.fixture.postedOps.length - _segOps;
      if (placed > 0 || ops > 0) {
        _fail(
          'non-primary-button-commits',
          'a right or middle mouse click sent $placed placement(s) and $ops op(s) with tool ${rig.tool.name}',
        );
      }
    }
    if (_segUps == 0 && _segCancels > 0 && !_segImpure) {
      final placed = rig.fixture.posted.length - _segPosted;
      final ops = rig.fixture.postedOps.length - _segOps;
      if (placed > 0 || ops > 0) {
        _fail(
          'cancel-commits',
          'a gesture that only ended in cancel sent $placed placement(s) and $ops op(s)',
        );
      }
    }
  }

  String _bannerText() {
    final texts = _tester.widgetList<Text>(
      find.descendant(
        of: find.byType(AppErrorState),
        matching: find.byType(Text),
      ),
    );
    return texts.map((t) => t.data).whereType<String>().join(' / ');
  }

  void _tilesStayOnBoard() {
    final board = rig.boardOnScreen.inflate(2);
    for (final rect in _tileRects()) {
      if (!board.contains(rect.topLeft) || !board.contains(rect.bottomRight)) {
        _fail(
          'tile-off-board',
          'a call tile sits at $rect, outside the board on screen $board',
        );
      }
    }
  }

  void _unbalanced(String name, List<({String id, bool ended})> frames) {
    final ids = frames.map((f) => f.id).toSet();
    final ended = frames.where((f) => f.ended).map((f) => f.id).toSet();
    final open = ids.difference(ended);
    if (open.isNotEmpty) {
      _fail(
        '$name-never-ended',
        '${open.length} preview session(s) sent frames and never an ended frame: ${open.take(3)}',
      );
    }
  }

  /// A plain pen stroke after the run: proves the pointer count really is zero.
  Future<void> _probe() async {
    while (rig.navigator.canPop()) {
      await rig.navigator.maybePop();
      await _tester.pump(const Duration(milliseconds: 400));
    }
    if (rig.tool != CanvasTool.pen) {
      await _tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await _tester.pump();
    }
    if (rig.tool != CanvasTool.pen) {
      final button = find.bySemanticsLabel('Pen');
      if (button.evaluate().isNotEmpty) {
        await _tester.tap(button.first, warnIfMissed: false);
        await _tester.pump();
      }
    }
    if (rig.tool != CanvasTool.pen) {
      _log('probe skipped, pen could not be armed (tool ${rig.tool.name})');
      return;
    }
    Offset? start;
    final board = rig.boardOnScreen.intersect(rig.surfaceRect);
    for (var i = 0; i < 80 && start == null; i++) {
      final p = _inRect(board.deflate(20));
      if (_reachesSurface(p) && _reachesSurface(p + const Offset(40, 0))) {
        start = p;
      }
    }
    if (start == null) {
      _log('probe skipped, no bare board point');
      return;
    }
    final before = rig.fixture.posted.length;
    final kind = rig.phone ? PointerDeviceKind.touch : PointerDeviceKind.mouse;
    final pointer = TestPointer(_nextPointer++, kind, _deviceFor(kind));
    _log('probe stroke ${kind.name} from ${_fmt(start)}');
    await _send(pointer.down(start, timeStamp: _clock));
    for (var i = 1; i <= 3; i++) {
      await _send(
        pointer.move(start + Offset(12.0 * i, 3.0 * i), timeStamp: _clock),
      );
    }
    await _send(pointer.up(timeStamp: _clock));
    await _tester.pump(const Duration(milliseconds: 400));
    await _tester.pump(const Duration(milliseconds: 400));
    if (rig.fixture.posted.length == before) {
      _fail(
        'probe-no-commit',
        'a plain pen stroke after the run committed nothing, so a pointer or gesture state leaked',
      );
    }
    final ex = _tester.takeException();
    if (ex != null) _fail('exception', '$ex');
  }
}

/// Prints one machine-readable line per violation and fails the test on any.
void reportFuzz(CanvasGestureFuzz fuzz, {required String mode}) {
  for (final v in fuzz.violations) {
    // ignore: avoid_print
    print(
      'FUZZ_VIOLATION ${jsonEncode({'mode': mode, 'seed': fuzz.seed, 'invariant': v.invariant, 'step': v.step, 'detail': v.detail, 'trace': v.trace})}',
    );
  }
  if (fuzz.violations.isNotEmpty) {
    fail(
      '$mode seed ${fuzz.seed}: ${fuzz.violations.join('\n')}\n'
      'last steps:\n${fuzz.violations.first.trace.reversed.take(40).toList().reversed.join('\n')}',
    );
  }
}
