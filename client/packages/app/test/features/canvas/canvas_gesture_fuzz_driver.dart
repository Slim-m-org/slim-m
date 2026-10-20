// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A seeded random pointer driver for the real canvas pane, and the
/// invariants it checks after every step and whenever every pointer is up.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_zoom_indicator.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_editor.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart' show AppErrorState;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_gesture_fuzz_model.dart';
import 'canvas_gesture_fuzz_rig.dart';
import 'canvas_pane_harness.dart';

part 'canvas_gesture_fuzz_actions.dart';
part 'canvas_gesture_fuzz_checks.dart';

/// One broken invariant, with enough of the sequence to replay it.
class FuzzViolation {
  FuzzViolation(this.invariant, this.detail, this.step, this.trace);

  final String invariant;
  final String detail;
  final int step;
  final List<String> trace;

  @override
  String toString() => '[$invariant] step $step: $detail';
}

class _Held {
  _Held(this.pointer, this.kind, this.pos, this.target);

  final TestPointer pointer;
  final PointerDeviceKind kind;
  final String target;
  Offset pos;
  Offset pan = Offset.zero;
  double scale = 1;
}

/// Weighted actions; the numbers only set how often each is tried.
const _weights = <String, int>{
  'down': 22,
  'move': 30,
  'up': 14,
  'cancel': 5,
  'toolKey': 5,
  'toolButton': 3,
  'wheel': 6,
  'trackpad': 4,
  'scaleEvent': 1,
  'live': 4,
  'edit': 3,
  'pump': 6,
  'hover': 3,
  'chrome': 5,
  'buttons': 2,
  'stroke': 8,
  'resize': 1,
  'noteEdit': 2,
};

class CanvasGestureFuzz {
  CanvasGestureFuzz(this.rig, this.seed, {this.toolSwitchMidGesture = true})
    : _rng = Random(seed),
      _server = FuzzServerModel(rig);

  /// False keeps tool keys, tool buttons and chrome taps to moments when no
  /// pointer is down, so the run isolates everything except that one trigger.
  final bool toolSwitchMidGesture;

  final FuzzRig rig;
  final FuzzServerModel _server;
  final int seed;
  final Random _rng;
  final violations = <FuzzViolation>[];
  final trace = <String>[];

  final _held = <int, _Held>{};
  var _nextPointer = 100;
  var _step = 0;
  var _clock = Duration.zero;
  var _liveCount = 0;

  var _segUps = 0;
  var _segCancels = 0;
  var _segImpure = false;
  var _segPrimary = false;
  var _segPosted = 0;
  var _segOps = 0;

  WidgetTester get _tester => rig.tester;
  CanvasDocument get _doc => rig.document;
  Size get _window => _tester.view.physicalSize / _tester.view.devicePixelRatio;

  // Each invariant is reported once per run, so one bug is one finding.
  void _fail(String invariant, String detail) {
    if (violations.any((v) => v.invariant == invariant)) return;
    violations.add(FuzzViolation(invariant, detail, _step, List.of(trace)));
  }

  void _log(String line) => trace.add('${_step.toString().padLeft(3)} $line');

  Future<void> run(int steps) async {
    for (_step = 0; _step < steps; _step++) {
      await _dismissModal();
      await _act(_pick());
      await _tester.pump(const Duration(milliseconds: 8));
      _clock += const Duration(milliseconds: 8);
      _stepInvariants();
      _logStateChanges();
      final ex = _tester.takeException();
      if (ex != null) _fail('exception', '$ex');
      if (_held.isEmpty && _segActive) await _segmentEnded();
    }
    await _releaseAll();
    await _segmentEnded();
    await _probe();
  }

  /// Closes the pane the way the app does and records anything its dispose threw.
  Future<void> finish() async {
    await rig.close();
    final ex = _tester.takeException();
    if (ex != null) _fail('exception-on-close', '$ex');
  }

  var _segActive = false;
  String? _lastElevated;
  String? _lastSelected;

  /// Notes selection and lift changes in the trace, which explain most failures.
  void _logStateChanges() {
    final lifted = _doc.elevatedObjectId.value;
    if (lifted != _lastElevated) _log('  -> lifted: $lifted');
    _lastElevated = lifted;
    final selected = _doc.selectedObjectId.value;
    if (selected != _lastSelected) _log('  -> selected: $selected');
    _lastSelected = selected;
  }

  String _pick() {
    var roll = _rng.nextInt(_weights.values.reduce((a, b) => a + b));
    for (final entry in _weights.entries) {
      roll -= entry.value;
      if (roll < 0) return entry.key;
    }
    return 'pump';
  }

  Future<void> _act(String action) async {
    switch (action) {
      case 'down':
        await _down();
      case 'move':
        await _move();
      case 'up':
        await _lift(cancel: false);
      case 'cancel':
        await _lift(cancel: true);
      case 'toolKey':
        await _toolKey();
      case 'toolButton':
        await _toolButton();
      case 'wheel':
        await _wheel();
      case 'trackpad':
        await _trackpad();
      case 'scaleEvent':
        await _scaleEvent();
      case 'live':
        await _live();
      case 'edit':
        await _edit();
      case 'pump':
        await _tester.pump(Duration(milliseconds: 1 + _rng.nextInt(400)));
        _clock += const Duration(milliseconds: 100);
      case 'hover':
        await _hover();
      case 'chrome':
        await _chromeTap();
      case 'buttons':
        await _changeButtons();
      case 'stroke':
        await _burstStroke();
      case 'resize':
        await _resizeWindow();
      case 'noteEdit':
        await _noteEdit();
    }
  }

  // Geometry ---------------------------------------------------------------

  Offset _inRect(Rect r) => Offset(
    r.left + _rng.nextDouble() * r.width,
    r.top + _rng.nextDouble() * r.height,
  );

  Offset _clamped(Offset o) => Offset(
    o.dx.clamp(0, _window.width - 1).toDouble(),
    o.dy.clamp(0, _window.height - 1).toDouble(),
  );

  List<Rect> _tileRects() => [
    for (
      var i = 0;
      i < find.byType(CanvasPresenceManipulableTile).evaluate().length;
      i++
    )
      _tester.getRect(find.byType(CanvasPresenceManipulableTile).at(i)),
  ];

  /// The zoom pill and view-mode buttons; the indicator widget itself spans the whole pane.
  List<Rect> _chipRects() {
    final chips = find.descendant(
      of: find.byType(CanvasZoomIndicator),
      matching: find.byType(InkWell),
    );
    return [
      for (var i = 0; i < chips.evaluate().length; i++)
        _tester.getRect(chips.at(i)),
    ];
  }

  List<Rect> _dockRects() => [
    for (var i = 0; i < find.byType(FloatingDockCard).evaluate().length; i++)
      _tester.getRect(find.byType(FloatingDockCard).at(i)),
  ];

  (Offset, String) _target({bool pointerDown = false}) {
    final surface = rig.surfaceRect;
    final board = rig.boardOnScreen.intersect(surface);
    // A press on a tool button switches the tool when it lifts, wherever the other pointers are.
    var roll = _rng.nextInt(100);
    if (pointerDown && !toolSwitchMidGesture && roll >= 64) {
      roll = roll < 88 ? 80 : 0;
    }
    if (roll < 32 && !board.isEmpty) return (_inRect(board), 'board');
    if (roll < 50) {
      final alive = rig.knownIds.where(_doc.isAlive).toList();
      if (alive.isNotEmpty) {
        final id = alive[_rng.nextInt(alive.length)];
        final b = _doc.objectBounds(id);
        if (b != null) {
          final rect = Rect.fromPoints(
            rig.toScreen(Offset(b.x, b.y)),
            rig.toScreen(Offset(b.x + b.w, b.y + b.h)),
          );
          return (_clamped(_inRect(rect)), 'object:$id');
        }
      }
    }
    if (roll < 64) {
      final tiles = _tileRects();
      if (tiles.isNotEmpty) {
        return (_clamped(_inRect(tiles[_rng.nextInt(tiles.length)])), 'tile');
      }
    }
    if (roll < 76) {
      final docks = _dockRects();
      if (docks.isNotEmpty) {
        return (_clamped(_inRect(docks[_rng.nextInt(docks.length)])), 'dock');
      }
    }
    if (roll < 88) {
      for (var i = 0; i < 12; i++) {
        final p = _inRect(surface);
        if (!rig.boardOnScreen.contains(p)) return (p, 'letterbox');
      }
    }
    if (roll < 93 && _chipRects().isNotEmpty) {
      final chips = _chipRects();
      return (_clamped(_inRect(chips[_rng.nextInt(chips.length)])), 'zoomChip');
    }
    return (_inRect(Offset.zero & _window), 'anywhere');
  }

  // Pointers ---------------------------------------------------------------

  int _deviceFor(PointerDeviceKind kind) => switch (kind) {
    PointerDeviceKind.mouse => 1,
    PointerDeviceKind.stylus => 50,
    PointerDeviceKind.trackpad => 60,
    _ => 0,
  };

  PointerDeviceKind? _pickKind() {
    final kinds = _held.values.map((h) => h.kind).toList();
    final touches = kinds.where((k) => k == PointerDeviceKind.touch).length;
    final pool = <PointerDeviceKind>[
      if (touches < 3) ...[
        PointerDeviceKind.touch,
        PointerDeviceKind.touch,
        if (rig.phone) ...[PointerDeviceKind.touch, PointerDeviceKind.touch],
      ],
      if (!kinds.contains(PointerDeviceKind.mouse)) ...[
        PointerDeviceKind.mouse,
        if (!rig.phone) PointerDeviceKind.mouse,
      ],
      if (!kinds.contains(PointerDeviceKind.stylus)) PointerDeviceKind.stylus,
    ];
    return pool.isEmpty ? null : pool[_rng.nextInt(pool.length)];
  }

  Future<void> _send(PointerEvent event) async {
    _clock += const Duration(milliseconds: 4);
    await _tester.sendEventToBinding(event);
  }

  void _beginSegment() {
    if (_segActive) return;
    _segActive = true;
    _segUps = 0;
    _segCancels = 0;
    _segImpure = false;
    _segPrimary = false;
    _segPosted = rig.fixture.posted.length;
    _segOps = rig.fixture.postedOps.length;
  }

  Future<void> _down({Offset? at, String? target, int? buttons}) async {
    final kind = _pickKind();
    if (kind == null) return _move();
    final (pos, where) = at == null
        ? _target(pointerDown: true)
        : (at, target ?? 'given');
    final chosen =
        buttons ??
        (kind == PointerDeviceKind.mouse
            ? const [
                kPrimaryButton,
                kPrimaryButton,
                kPrimaryButton,
                kPrimaryButton,
                kMiddleMouseButton,
                kSecondaryButton,
              ][_rng.nextInt(6)]
            : kind == PointerDeviceKind.stylus && _rng.nextInt(4) == 0
            ? const [
                kPrimaryButton | kPrimaryStylusButton,
                kPrimaryButton | kSecondaryStylusButton,
              ][_rng.nextInt(2)]
            : kPrimaryButton);
    final id = _nextPointer++;
    final pointer = TestPointer(id, kind, _deviceFor(kind), chosen);
    _beginSegment();
    _held[id] = _Held(pointer, kind, pos, where);
    _notePrimary(kind, chosen);
    _log(
      'down ${kind.name}#$id b=$chosen @${_fmt(pos)} on $where tool=${rig.tool.name} '
      'surface=${_reachesSurface(pos)} external=${_doc.externalPointers.count}',
    );
    await _send(pointer.down(pos, timeStamp: _clock));
  }

  /// A contact that is not a primary-button press: a right or middle click.
  void _notePrimary(PointerDeviceKind kind, int buttons) {
    if (kind != PointerDeviceKind.mouse || buttons & kPrimaryButton != 0) {
      _segPrimary = true;
    }
  }

  String _fmt(Offset o) => '(${o.dx.round()},${o.dy.round()})';

  _Held? _anyHeld({bool trackpad = false}) {
    final list = _held.values
        .where((h) => (h.kind == PointerDeviceKind.trackpad) == trackpad)
        .toList();
    return list.isEmpty ? null : list[_rng.nextInt(list.length)];
  }

  Future<void> _move() async {
    final held = _held.values.isEmpty
        ? null
        : _held.values.elementAt(_rng.nextInt(_held.length));
    if (held == null) return _hover();
    if (held.kind == PointerDeviceKind.trackpad) return _trackpadUpdate(held);
    final jump = _rng.nextInt(10);
    final next = jump == 0
        ? _target().$1
        : _clamped(
            held.pos +
                Offset(
                  (_rng.nextDouble() - 0.5) * (jump < 3 ? 400 : 70),
                  (_rng.nextDouble() - 0.5) * (jump < 3 ? 400 : 70),
                ),
          );
    _log('move ${held.kind.name}#${held.pointer.pointer} -> ${_fmt(next)}');
    held.pos = next;
    await _send(held.pointer.move(next, timeStamp: _clock));
  }

  Future<void> _lift({required bool cancel}) async {
    final held = _held.values.isEmpty
        ? null
        : _held.values.elementAt(_rng.nextInt(_held.length));
    if (held == null) return;
    await _end(held, cancel: cancel);
  }

  Future<void> _end(_Held held, {required bool cancel}) async {
    final id = held.pointer.pointer;
    _held.remove(id);
    if (held.kind == PointerDeviceKind.trackpad) {
      _segUps++;
      _log('trackpad end #$id');
      await _send(held.pointer.panZoomEnd(timeStamp: _clock));
      return;
    }
    if (cancel) {
      _segCancels++;
      _log('cancel ${held.kind.name}#$id');
      await _send(held.pointer.cancel(timeStamp: _clock));
    } else {
      _segUps++;
      _log('up ${held.kind.name}#$id');
      await _send(held.pointer.up(timeStamp: _clock));
    }
  }

  Future<void> _releaseAll() async {
    while (_held.isNotEmpty) {
      await _end(_held.values.first, cancel: _rng.nextInt(4) == 0);
      await _tester.pump(const Duration(milliseconds: 8));
      _stepInvariants();
    }
  }

  Future<void> _hover() async {
    if (_held.values.any((h) => h.kind == PointerDeviceKind.mouse)) return;
    final mouse = TestPointer(1, PointerDeviceKind.mouse, 1);
    final pos = _target().$1;
    await _send(mouse.hover(pos, timeStamp: _clock));
  }

  Future<void> _changeButtons() async {
    final held = _held.values
        .where((h) => h.kind == PointerDeviceKind.mouse)
        .firstOrNull;
    if (held == null) return;
    final next = const [
      kPrimaryButton | kMiddleMouseButton,
      kMiddleMouseButton,
      kPrimaryButton,
      kPrimaryButton | kSecondaryButton,
    ][_rng.nextInt(4)];
    _notePrimary(PointerDeviceKind.mouse, next);
    _log('buttons mouse#${held.pointer.pointer} -> $next');
    await _send(held.pointer.move(held.pos, buttons: next, timeStamp: _clock));
  }

  /// A whole believable stroke in one go, so most runs contain real drags.
  Future<void> _burstStroke() async {
    if (_held.length >= 3) return;
    final kind = _pickKind();
    if (kind == null) return;
    final (start, where) = _target(pointerDown: true);
    final id = _nextPointer++;
    final pointer = TestPointer(id, kind, _deviceFor(kind));
    _beginSegment();
    _segPrimary = true;
    _log(
      'burst ${kind.name}#$id from ${_fmt(start)} on $where tool=${rig.tool.name}',
    );
    await _send(pointer.down(start, timeStamp: _clock));
    var pos = start;
    final dir = _rng.nextDouble() * 2 * pi;
    for (var i = 0; i < 4 + _rng.nextInt(10); i++) {
      pos = _clamped(
        pos + Offset.fromDirection(dir + (_rng.nextDouble() - 0.5), 14),
      );
      await _send(pointer.move(pos, timeStamp: _clock));
      await _tester.pump(const Duration(milliseconds: 8));
      _stepInvariants();
    }
    if (_rng.nextInt(8) == 0) {
      _segCancels++;
      _log('burst cancel #$id');
      await _send(pointer.cancel(timeStamp: _clock));
    } else {
      _segUps++;
      _log('burst up #$id');
      await _send(pointer.up(timeStamp: _clock));
    }
  }
}
