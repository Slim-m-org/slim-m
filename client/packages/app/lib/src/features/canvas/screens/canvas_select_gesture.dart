// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Move tool on the board: moving or resizing what is under the press,
/// panning from empty board, following someone's cursor, and opening a note
/// for editing on a double click or a second tap.
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../permissions.dart';
import '../../../providers/effective_me.dart';
import '../../channels/providers/channel_permissions.dart';
import 'canvas_drag_pan.dart';
import 'canvas_engine.dart';
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
  });

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

  final _dragPan = CanvasDragPan();

  /// The last mouse click on a note, so a second one soon after is a double click.
  ({String id, DateTime at})? _lastNoteClick;

  /// What was selected when the current select press began, so a tap edits a note only on its second tap.
  String? _selectedBeforeDown;

  CanvasDocument get _document => engine.document;
  CanvasOpsController get _ops => engine.ops;

  /// A finished select gesture that never became a drag: a double click with
  /// a mouse, or a single tap with a finger or a pen, on the selected note.
  void tap(Offset world, PointerDeviceKind kind) {
    final id = _document.selectedObjectId.value;
    if (id == null && _followCursorAt(world)) return;
    final bounds = id == null ? null : _document.objectBounds(id);
    final onNote =
        id != null &&
        bounds != null &&
        (_document.kindOf(id) == CanvasObjectKind.note ||
            _document.kindOf(id) == CanvasObjectKind.text) &&
        Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h).contains(world);
    if (!onNote) {
      _lastNoteClick = null;
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
    final me = ref.read(meProvider).valueOrNull;
    // A safe read, not a cold one: build() already watches this same family instance every frame.
    final manageCanvas = ref
        .read(myChannelPermissionsProvider(channelId()))
        .hasPermission(Perm.manageCanvas);
    _ops.beginSelect(
      world,
      manageCanvas: manageCanvas,
      selfId: me?.id,
      touch: touch(),
    );
    // Nothing to move or resize under the pointer: the pan tool pans, with one finger too.
    if (_ops.activeMove == null) _dragPan.begin(world);
  }

  /// Images keep their aspect and notes or shapes resize freely; Shift flips either, Alt moves freely, touch always snaps.
  /// Read on every drag point so releasing a key mid-drag takes effect at once.
  void drag(Offset world) {
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
    );
    if (_ops.activeMove case final move?) {
      engine.objectPreviewRelay.reportLocal(move.id, move.box);
    }
  }

  bool _aspectLocked({required bool flipped}) {
    final id = _document.selectedObjectId.value;
    final isImage =
        id != null && _document.kindOf(id) == CanvasObjectKind.image;
    return isImage != flipped;
  }

  Future<void> cancel() async {
    _dragPan.end();
    final restored = _ops.cancelSelect();
    engine.objectPreviewRelay.endLocal(restored?.box);
    changed();
  }

  Future<void> end() async {
    _dragPan.end();
    engine.objectPreviewRelay.endLocal(_ops.activeMove?.box);
    await _ops.endSelect();
    changed();
  }
}
