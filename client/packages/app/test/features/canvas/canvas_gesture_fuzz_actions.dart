// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_gesture_fuzz_driver.dart';

/// Everything the fuzz does besides plain pointer presses: trackpad, wheel, tool
/// switches, remote edits, window changes, note editing and chrome taps.
extension _FuzzActions on CanvasGestureFuzz {
  // Trackpad, wheel and scale ------------------------------------------------

  Future<void> _trackpad() async {
    final held = _anyHeld(trackpad: true);
    if (held != null) {
      return _rng.nextInt(3) == 0
          ? _end(held, cancel: false)
          : _trackpadUpdate(held);
    }
    if (_held.length >= 3) return;
    final id = _nextPointer++;
    final pointer = TestPointer(id, PointerDeviceKind.trackpad, 60);
    final pos = _target().$1;
    _beginSegment();
    _held[id] = _Held(pointer, PointerDeviceKind.trackpad, pos, 'trackpad');
    _log('trackpad start #$id @${_fmt(pos)}');
    await _send(pointer.panZoomStart(pos, timeStamp: _clock));
  }

  Future<void> _trackpadUpdate(_Held held) async {
    held.pan += Offset(
      (_rng.nextDouble() - 0.5) * 80,
      (_rng.nextDouble() - 0.5) * 80,
    );
    held.scale = (held.scale * (0.85 + _rng.nextDouble() * 0.3)).clamp(0.2, 5);
    _log(
      'trackpad update #${held.pointer.pointer} pan=${_fmt(held.pan)} scale=${held.scale.toStringAsFixed(2)}',
    );
    await _send(
      held.pointer.panZoomUpdate(
        held.pos,
        pan: held.pan,
        scale: held.scale,
        timeStamp: _clock,
      ),
    );
  }

  Future<void> _wheel() async {
    _segImpure = true;
    final pos = _target().$1;
    final mod = _rng.nextInt(5);
    final key = switch (mod) {
      1 => LogicalKeyboardKey.controlLeft,
      2 => LogicalKeyboardKey.shiftLeft,
      3 => LogicalKeyboardKey.metaLeft,
      _ => null,
    };
    final delta = Offset(
      mod == 4 ? (_rng.nextDouble() - 0.5) * 200 : 0,
      (_rng.nextDouble() - 0.5) * 300,
    );
    _log('wheel @${_fmt(pos)} d=${_fmt(delta)} mod=${key?.keyLabel ?? '-'}');
    if (key != null) await _tester.sendKeyDownEvent(key);
    await _send(
      PointerScrollEvent(
        viewId: _tester.view.viewId,
        timeStamp: _clock,
        kind: PointerDeviceKind.mouse,
        device: 1,
        position: pos,
        scrollDelta: delta,
      ),
    );
    if (key != null) await _tester.sendKeyUpEvent(key);
  }

  Future<void> _scaleEvent() async {
    _segImpure = true;
    final pos = _target().$1;
    final scale = 0.3 + _rng.nextDouble() * 2.2;
    _log('scaleEvent @${_fmt(pos)} x${scale.toStringAsFixed(2)}');
    await _send(
      PointerScaleEvent(
        viewId: _tester.view.viewId,
        timeStamp: _clock,
        kind: PointerDeviceKind.mouse,
        device: 1,
        position: pos,
        scale: scale,
      ),
    );
  }

  // Tools, keys and remote edits ---------------------------------------------

  Future<void> _toolKey() async {
    if (!toolSwitchMidGesture && _held.isNotEmpty) return;
    final key = [
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyE,
    ][_rng.nextInt(5)];
    _log('toolKey ${key.keyLabel} (held=${_held.length})');
    await _tester.sendKeyEvent(key);
  }

  Future<void> _toolButton() async {
    if (!toolSwitchMidGesture && _held.isNotEmpty) return;
    final label = ['Move', 'Pen', 'Note', 'Shape', 'Eraser'][_rng.nextInt(5)];
    final button = find.bySemanticsLabel(label);
    if (button.evaluate().isEmpty) return;
    final rect = _tester.getRect(button.first);
    _log('toolButton $label (held=${_held.length})');
    final pointer = TestPointer(_nextPointer++, PointerDeviceKind.touch);
    await _send(pointer.down(rect.center, timeStamp: _clock));
    await _send(pointer.up(timeStamp: _clock));
  }

  Future<void> _edit() async {
    _segImpure = true;
    final key = [
      (LogicalKeyboardKey.delete, false),
      (LogicalKeyboardKey.backspace, false),
      (LogicalKeyboardKey.keyZ, true),
      (LogicalKeyboardKey.keyY, true),
    ][_rng.nextInt(4)];
    _log('edit ${key.$1.keyLabel} ctrl=${key.$2} (held=${_held.length})');
    if (key.$2) await _tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _tester.sendKeyEvent(key.$1);
    if (key.$2) await _tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  Future<void> _live() async {
    _segImpure = true;
    _server.absorbSent();
    final alive = rig.knownIds.where(_doc.isAlive).toList();
    final roll = _rng.nextInt(10);
    final seq = ++rig.liveSeq;
    if (roll < 4 || alive.isEmpty) {
      final id = 'live${_liveCount++}';
      rig.knownIds.add(id);
      final json = canvasObjectJson(id, seq: seq, authorId: 'other')
        ..['x'] = 100.0 + _rng.nextInt(1600)
        ..['y'] = 100.0 + _rng.nextInt(800)
        ..['w'] = 120.0
        ..['h'] = 80.0;
      _log('live place $id');
      _server.livePlaced(json);
      rig.fixture.objects.add(json);
      rig.fixture.events.add(
        api.CanvasObjectPlaced(
          channelId: 'c1',
          object: api.CanvasObject.fromJson(json),
        ),
      );
    } else if (roll < 7) {
      final id = alive[_rng.nextInt(alive.length)];
      _log('live remove $id');
      _server.liveRemoved(id);
      rig.fixture.objects.removeWhere((o) => o['id'] == id);
      rig.fixture.events.add(
        api.CanvasObjectsRemoved(
          channelId: 'c1',
          seq: seq,
          opId: 'op$seq',
          objectIds: [id],
        ),
      );
    } else {
      final id = alive[_rng.nextInt(alive.length)];
      _log('live move $id');
      final box = Rect.fromLTWH(
        50.0 + _rng.nextInt(1500),
        50.0 + _rng.nextInt(700),
        160,
        100,
      );
      _server.liveMoved(id, box);
      for (final o in rig.fixture.objects.where((o) => o['id'] == id)) {
        o
          ..['x'] = box.left
          ..['y'] = box.top
          ..['w'] = box.width
          ..['h'] = box.height;
      }
      rig.fixture.events.add(
        api.CanvasObjectMoved(
          channelId: 'c1',
          seq: seq,
          opId: 'op$seq',
          objectId: id,
          x: box.left,
          y: box.top,
          w: box.width,
          h: box.height,
        ),
      );
    }
    await _tester.pump();
  }

  Future<void> _dismissModal() async {
    if (!rig.navigator.canPop() || _rng.nextInt(10) < 4) return;
    _log('dismiss modal');
    _segImpure = true;
    await rig.navigator.maybePop();
    await _tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> _resizeWindow() async {
    final sizes = rig.phone
        ? const [Size(390, 844), Size(844, 390), Size(360, 640)]
        : const [
            Size(1280, 800),
            Size(1024, 700),
            Size(1920, 1080),
            Size(700, 900),
          ];
    final next = sizes[_rng.nextInt(sizes.length)];
    _log(
      'resize window -> ${next.width.round()}x${next.height.round()} (held=${_held.length})',
    );
    _tester.view.physicalSize = next;
    await _tester.pump(const Duration(milliseconds: 50));
  }

  /// Double-clicks a note to open its editor, then tries to type tool keys into it.
  Future<void> _noteEdit() async {
    if (_held.isNotEmpty || rig.tool != CanvasTool.pan) return;
    _segImpure = true;
    if (find.byType(CanvasNoteEditor).evaluate().isEmpty) {
      final notes = rig.knownIds
          .where(
            (id) =>
                _doc.isAlive(id) && _doc.kindOf(id) == CanvasObjectKind.note,
          )
          .toList();
      if (notes.isEmpty) return;
      final id = notes[_rng.nextInt(notes.length)];
      final b = _doc.objectBounds(id)!;
      final at = rig.toScreen(Offset(b.x + b.w / 2, b.y + b.h / 2));
      if (!rig.surfaceRect.contains(at)) return;
      _log('double click note $id @${_fmt(at)}');
      for (var i = 0; i < 3; i++) {
        final mouse = TestPointer(_nextPointer++, PointerDeviceKind.mouse, 1);
        await _send(mouse.down(at, timeStamp: _clock));
        await _send(mouse.up(timeStamp: _clock));
        await _tester.pump(const Duration(milliseconds: 60));
      }
      return;
    }
    final tool = rig.tool;
    final key = [
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyN,
    ][_rng.nextInt(3)];
    _log('type ${key.keyLabel} into the open note editor');
    await _tester.sendKeyEvent(key);
    await _tester.pump();
    if (rig.tool != tool) {
      _fail(
        'typing-switches-tool',
        'typing ${key.keyLabel} in the note editor changed the tool ${tool.name} -> ${rig.tool.name}',
      );
    }
    if (_rng.nextBool()) await _tester.sendKeyEvent(LogicalKeyboardKey.escape);
  }

  // Chrome -------------------------------------------------------------------

  bool _reachesSurface(Offset pos) {
    final result = HitTestResult();
    _tester.binding.hitTestInView(result, pos, _tester.view.viewId);
    final listener = _tester.renderObject(
      find
          .descendant(
            of: find.byType(CanvasSurface),
            matching: find.byType(Listener),
          )
          .first,
    );
    return result.path.any((entry) => identical(entry.target, listener));
  }

  Future<void> _chromeTap() async {
    if (!toolSwitchMidGesture && _held.isNotEmpty) return;
    _segImpure = true;
    final rects = [
      for (final r in _dockRects()) ('dock', r.deflate(6)),
      for (final r in _chipRects()) ('chip', r.deflate(2)),
    ].where((r) => !r.$2.isEmpty).toList();
    if (rects.isEmpty) return;
    final (source, rect) = rects[_rng.nextInt(rects.length)];
    final pos = _inRect(rect);
    final falls = _reachesSurface(pos);
    final tool = rig.tool;
    final before = (
      rig.fixture.posted.length,
      rig.fixture.postedOps.length,
      _doc.objectCount.value,
      rig.navigator.canPop(),
      _doc.camera,
    );
    final kind = rig.phone || _rng.nextBool()
        ? PointerDeviceKind.touch
        : PointerDeviceKind.mouse;
    _log(
      'chrome tap ${kind.name} @${_fmt(pos)} in $source $rect reachesSurface=$falls tool=${tool.name}',
    );
    final pointer = TestPointer(_nextPointer++, kind, _deviceFor(kind));
    _server.absorbSent();
    await _send(pointer.down(pos, timeStamp: _clock));
    await _send(pointer.up(timeStamp: _clock));
    await _tester.pump(const Duration(milliseconds: 300));
    _server.absorbSent();
    if (!falls) return;
    final after = (
      rig.fixture.posted.length,
      rig.fixture.postedOps.length,
      _doc.objectCount.value,
      rig.navigator.canPop(),
      _doc.camera,
    );
    if (after != before && tool != CanvasTool.pan) {
      _fail(
        'chrome-tap-draws',
        'a ${kind.name} tap at ${_fmt(pos)} inside the $source $rect (tool ${tool.name}) '
            'reached the board: posted ${before.$1}->${after.$1}, ops ${before.$2}->${after.$2}, '
            'objects ${before.$3}->${after.$3}, sheet ${before.$4}->${after.$4}',
      );
    }
  }
}
