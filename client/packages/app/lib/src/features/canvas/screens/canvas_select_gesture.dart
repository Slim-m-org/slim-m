// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Move tool on the board: moving or resizing what is under the press,
/// panning from empty board, following someone's cursor, and opening a note
/// for editing on a double click or a second tap.
library;

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kLongPressTimeout;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../permissions.dart';
import '../../../providers/effective_me.dart';
import '../../channels/providers/channel_permissions.dart';
import 'canvas_drag_pan.dart';
import 'canvas_marquee_gesture.dart';
import 'canvas_edge_gesture.dart';
import 'canvas_engine.dart';
import 'canvas_note_taps.dart';
import 'canvas_ops_controller.dart';

/// How close a tap must land to someone's cursor to follow them, in screen pixels.
const double _cursorTapReachPx = 20;

/// How soon a second click on a note makes a double click.
const _doubleClickWindow = Duration(milliseconds: 400);

class CanvasSelectGesture {
  CanvasSelectGesture({
    required this.engine,
    required this.ref,
    required this.channelId,
    required this.boardFocus,
    required this.editing,
    required this.touch,
    required this.spectating,
    required this.editNote,
    required this.changed,
    required CanvasTool Function() tool,
    this.noteSpans,
    this.mayRestyle,
    this.placeText,
  }) : _tool = tool {
    edges = CanvasEdgeGesture(
      engine: engine,
      ref: ref,
      channelId: channelId,
      tool: tool,
      touch: touch,
      manageCanvas: () => ref
          .read(myChannelPermissionsProvider(channelId()))
          .hasPermission(Perm.manageCanvas),
    );
  }

  final CanvasTool Function() _tool;

  /// Connections: the side dots, end handles and the Connect tool's drag.
  late final CanvasEdgeGesture edges;

  void dispose() => edges.dispose();

  final CanvasEngine engine;
  final WidgetRef ref;
  final String Function() channelId;
  final FocusNode boardFocus;

  /// Whether a note's in-place editor is open, which keeps the keyboard.
  final bool Function() editing;

  /// Whether a press reaches as far as a finger does.
  final bool Function() touch;
  final bool Function() spectating;

  /// Opens the in-place editor for the note with this id, where it may be edited.
  final void Function(String id) editNote;

  /// Rebuilds the pane.
  final VoidCallback changed;

  /// How the board lays a note's text out, so a tap can find the box or link it hit.
  final NoteSpanBuilder? Function()? noteSpans;

  /// Whether this person may change the note, which a task box needs.
  final bool Function(String id)? mayRestyle;

  /// Opens a new text box at the point a double click on empty board landed.
  final void Function(Offset world)? placeText;

  /// The last mouse click on empty board, so a second one soon after is a double click.
  ({Offset world, DateTime at})? _lastEmptyClick;

  final _dragPan = CanvasDragPan();

  /// The drag box, drawn from a mouse press on empty board or a finger held there.
  late final _marquee = CanvasMarqueeGesture(_document, accepts: mayPick);

  /// When the current press on empty board began, so a finger held there turns into a box.
  DateTime? _emptyPressAt;
  Offset? _emptyPressWorld;

  /// A modifier press that already toggled an object, whose drag must do nothing.
  bool _modifierPress = false;

  /// A Shift press that added to the pick, whose plain release must not narrow it again.
  bool _keepPickOnTap = false;

  /// The pickable object under the current press, if any.
  String? _pressedPickable;

  /// The last mouse click on a note, so a second one soon after is a double click.
  ({String id, DateTime at})? _lastNoteClick;

  /// What was selected when the current select press began, so a tap edits a note only on its second tap.
  String? _selectedBeforeDown;

  CanvasDocument get _document => engine.document;
  CanvasOpsController get _ops => engine.ops;

  /// A finished select gesture that never became a drag: a double click with
  /// a mouse, or a single tap with a finger or a pen, on the selected note.
  void tap(Offset world, PointerDeviceKind kind) {
    if (_collapseGroupTap(world)) return;
    final id = _document.selectedObjectId.value;
    if (id != null && _document.edges.isAlive(id)) {
      edges.tap(world, kind, _selectedBeforeDown);
      return;
    }
    if (id == null && _followCursorAt(world)) return;
    if (_noteContentTapped(world)) return;
    final bounds = id == null ? null : _document.objectBounds(id);
    final onNote =
        id != null &&
        bounds != null &&
        (_document.kindOf(id) == CanvasObjectKind.note ||
            _document.kindOf(id) == CanvasObjectKind.text) &&
        Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h).contains(world);
    if (!onNote) {
      _lastNoteClick = null;
      if (id == null) _emptyClick(world, kind);
      return;
    }
    if (kind != PointerDeviceKind.mouse) {
      // The first tap selects the note; only a tap on a note that was already selected edits it.
      if (id != _selectedBeforeDown) return;
    } else {
      final last = _lastNoteClick;
      final now = clock.now();
      _lastNoteClick = (id: id, at: now);
      if (last == null ||
          last.id != id ||
          now.difference(last.at) > _doubleClickWindow) {
        return;
      }
      _lastNoteClick = null;
    }
    editNote(id);
  }

  /// A second mouse click close to the first on empty board starts a text box there.
  void _emptyClick(Offset world, PointerDeviceKind kind) {
    if (kind != PointerDeviceKind.mouse || placeText == null) return;
    if (hitTestTopmost(_document, world) != null) return;
    final last = _lastEmptyClick;
    final now = clock.now();
    final near =
        last != null &&
        (last.world - world).distance * _document.camera.zoom <=
            canvasDragPanSlopPx;
    if (!near || now.difference(last.at) > _doubleClickWindow) {
      _lastEmptyClick = (world: world, at: now);
      return;
    }
    _lastEmptyClick = null;
    placeText!(world);
  }

  /// A task box or a link in a note's text was hit; true when it took the tap.
  bool _noteContentTapped(Offset world) {
    final spans = noteSpans?.call();
    if (spans == null) return false;
    final tapped = noteTapAt(
      _document,
      world,
      spans,
      canToggle: mayToggle(world),
    );
    switch (tapped) {
      case NoteCheckTap(:final objectId, :final line):
        unawaited(_ops.toggleTask(objectId, line).then((_) => changed()));
      case NoteLinkTap(:final url):
        // A tap that only selects the note must not leave the app.
        if (hitTestTopmost(_document, world) != _selectedBeforeDown) {
          return false;
        }
        openNoteLink(ref.context, ref, url);
      case null:
        return false;
    }
    _lastNoteClick = null;
    return true;
  }

  /// Task boxes answer only a person who may edit the note under the tap, and never a locked one.
  bool mayToggle(Offset world) {
    final id = hitTestTopmost(_document, world);
    return id != null &&
        !_ops.isLocked(id) &&
        !spectating() &&
        (mayRestyle?.call(id) ?? false);
  }

  /// A tap on someone's cursor follows them instead of selecting under it.
  bool _followCursorAt(Offset world) {
    final reach = _cursorTapReachPx / _document.camera.zoom;
    final hit = engine.cursors.all
        .where((c) => (Offset(c.x, c.y) - world).distance <= reach)
        .firstOrNull;
    if (hit == null) return false;
    final relay = engine.viewRelay;
    relay.following.value == hit.id
        ? relay.stopFollowing()
        : relay.follow(hit.id);
    return true;
  }

  bool grabsHandleAt(Offset world, PointerDeviceKind kind) {
    final me = ref.read(meProvider).valueOrNull;
    return _ops.hitsResizeHandle(
      world,
      manageCanvas: ref
          .read(myChannelPermissionsProvider(channelId()))
          .hasPermission(Perm.manageCanvas),
      selfId: me?.id,
      touch: touch(),
    );
  }

  void start(Offset world) {
    if (!editing() && !boardFocus.hasPrimaryFocus) {
      boardFocus.requestFocus();
    }
    // A spectator moves nothing but the camera.
    if (spectating()) return _dragPan.begin(world);
    _selectedBeforeDown = _document.selectedObjectId.value;
    _modifierPress = false;
    _keepPickOnTap = false;
    _pressedPickable = null;
    if (edges.start(world)) {
      // A press that only selected a connection is still a pan if it moves.
      if (!edges.active) _dragPan.begin(world);
      return;
    }
    if (_tool() == CanvasTool.connect) return _dragPan.begin(world);
    if (_startGroupPress(world)) return;
    // A modifier press that found nothing pickable keeps what is picked and may grow it with a box.
    if (_modifierHeld && _pressedPickable == null) {
      return _marquee.begin(world, additive: true);
    }
    final me = ref.read(meProvider).valueOrNull;
    _ops.beginSelect(
      world,
      manageCanvas: _manageCanvas,
      selfId: me?.id,
      touch: touch(),
    );
    if (_ops.activeMove != null) return;
    // Nothing to move or resize under the pointer: a mouse draws a box, a finger pans or, held, draws one.
    if (_document.selectedObjectId.value == null) {
      _document.multiSelection.clear();
      _armEmptyPress(world);
    } else {
      _dragPan.begin(world);
    }
  }

  bool get _manageCanvas => ref
      .read(myChannelPermissionsProvider(channelId()))
      .hasPermission(Perm.manageCanvas);

  /// Whether this person may pick [id] into a group: not locked, and theirs or any with MANAGE_CANVAS.
  bool mayPick(String id) =>
      !_ops.isLocked(id) &&
      (_manageCanvas ||
          _document.authorIdOf(id) == ref.read(meProvider).valueOrNull?.id);

  bool get _modifierHeld {
    final keys = HardwareKeyboard.instance;
    return keys.isControlPressed || keys.isMetaPressed || keys.isShiftPressed;
  }

  /// A finger or a pen, whatever the window's width: a mouse on a narrow window still drags a box at once.
  bool get _fingerDown => switch (_document.lastPointerKind) {
    PointerDeviceKind.touch ||
    PointerDeviceKind.stylus ||
    PointerDeviceKind.invertedStylus => true,
    _ => false,
  };

  void _armEmptyPress(Offset world) {
    if (_fingerDown) {
      _emptyPressAt = clock.now();
      _emptyPressWorld = world;
      return _dragPan.begin(world);
    }
    _marquee.begin(world, additive: _modifierHeld);
  }

  /// A press on an object picked into a group, or a modifier press on one; true when it took the press.
  bool _startGroupPress(Offset world) {
    final hit = hitTestTopmost(
      _document,
      world,
      touch: touch(),
      allowed: (stroke) => mayPick(stroke.id),
    );
    if (hit == null || _document.kindOf(hit) == CanvasObjectKind.stroke) {
      return false;
    }
    _pressedPickable = hit;
    final picked = _document.multiSelection;
    if (_modifierHeld) return _startModifierPress(world, hit);
    if (picked.ids.value.length < 2 || !picked.ids.value.contains(hit)) {
      return false;
    }
    final me = ref.read(meProvider).valueOrNull;
    final dragging = _ops.beginGroupDrag(
      world,
      picked.ids.value,
      manageCanvas: _manageCanvas,
      selfId: me?.id,
    );
    if (!dragging) _modifierPress = true;
    return true;
  }

  /// Ctrl or Cmd toggles [hit] and drags nothing; Shift adds it, and what is then picked together drags as a group.
  bool _startModifierPress(Offset world, String hit) {
    final keys = HardwareKeyboard.instance;
    final picked = _document.multiSelection;
    if (keys.isControlPressed || keys.isMetaPressed) {
      _modifierPress = true;
      picked.toggle(hit);
      return true;
    }
    picked.add([hit]);
    // One object alone is the ordinary selection, dragged the ordinary way.
    if (picked.ids.value.length < 2) return false;
    _keepPickOnTap = true;
    final me = ref.read(meProvider).valueOrNull;
    final dragging = _ops.beginGroupDrag(
      world,
      picked.ids.value,
      manageCanvas: _manageCanvas,
      selfId: me?.id,
    );
    if (!dragging) _modifierPress = true;
    return true;
  }

  /// A plain click on one object of a group picks just that object, as a drag from it would have moved them all.
  bool _collapseGroupTap(Offset world) {
    final picked = _document.multiSelection;
    if (_modifierPress || _keepPickOnTap) return true;
    if (picked.ids.value.isEmpty) return false;
    final hit = hitTestTopmost(_document, world, touch: touch());
    picked.select(
      hit != null && picked.ids.value.contains(hit) ? [hit] : const [],
    );
    return true;
  }

  /// Images keep their aspect and notes or shapes resize freely; Shift flips either, Alt moves freely, touch always snaps.
  /// Read on every drag point so releasing a key mid-drag takes effect at once.
  void drag(Offset world) {
    if (edges.active) return edges.drag(world);
    if (_modifierPress) return;
    _holdBecomesBox(world);
    if (_marquee.armed) return _marquee.drag(world);
    if (_dragPan.active) {
      _dragPan.drag(world, _document);
      // A stroke is selected by a tap; a drag across it is a pan.
      if (_dragPan.moving) _document.selectedObjectId.value = null;
      return;
    }
    _ops.dragSelect(
      world,
      lockAspect: _aspectLocked(
        flipped: HardwareKeyboard.instance.isShiftPressed,
      ),
      snap: !HardwareKeyboard.instance.isAltPressed,
      lockAxis: HardwareKeyboard.instance.isShiftPressed,
    );
    if (_ops.activeMove case final move?) {
      engine.objectPreviewRelay.reportLocal(move.id, move.box);
    }
  }

  /// A finger held still on empty board before it moved draws a box instead of panning.
  void _holdBecomesBox(Offset world) {
    final at = _emptyPressAt;
    final from = _emptyPressWorld;
    if (at == null || from == null || _dragPan.moving) return;
    if (clock.now().difference(at) < kLongPressTimeout) return;
    _emptyPressAt = null;
    _dragPan.end();
    _marquee.begin(from, additive: false);
  }

  bool _aspectLocked({required bool flipped}) {
    final id = _document.selectedObjectId.value;
    final isImage =
        id != null && _document.kindOf(id) == CanvasObjectKind.image;
    return isImage != flipped;
  }

  void _endBox() {
    _marquee.end();
    _emptyPressAt = null;
    _emptyPressWorld = null;
  }

  Future<void> cancel() async {
    _dragPan.end();
    _endBox();
    if (edges.active) {
      edges.cancel();
      changed();
      return;
    }
    final restored = _ops.cancelSelect();
    engine.objectPreviewRelay.endLocal(restored?.box);
    changed();
  }

  Future<void> end() async {
    _dragPan.end();
    _endBox();
    if (edges.active) {
      await edges.end();
      changed();
      return;
    }
    engine.objectPreviewRelay.endLocal(_ops.activeMove?.box);
    await _ops.endSelect();
    changed();
  }
}
