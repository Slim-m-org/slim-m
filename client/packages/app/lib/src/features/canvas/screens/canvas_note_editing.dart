// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The life of one note being typed in place: opening it, a draft that is not placed yet, committing, cancelling and restyling.
///
/// A draft is a note that exists only on this device until its text is committed, so nobody sees it being typed.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show AppTokens;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../ids.dart';
import '../providers/canvas_note_style.dart';
import '../widgets/canvas_note_editor.dart';
import 'canvas_note_bar_layer.dart';
import 'canvas_engine.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_ops_controller.dart';
import 'canvas_quick_placement.dart';

class CanvasNoteEditing {
  CanvasNoteEditing({
    required this.engine,
    required this.placement,
    required this.ref,
    required this.changed,
    required this.onPlaced,
    required this.focusBoard,
    required this.spectating,
    required this.currentTool,
  });

  final CanvasEngine engine;
  final CanvasQuickPlacement Function() placement;
  final WidgetRef ref;
  final void Function([VoidCallback? mutate]) changed;

  /// Selects a freshly placed note, unless the person moved on while it saved.
  final void Function(String id, CanvasTool startedWith) onPlaced;
  final VoidCallback focusBoard;
  final bool Function() spectating;
  final CanvasTool Function() currentTool;

  CanvasNoteEditSession? session;

  /// Where the keyboard lands when the object menu asks for the style bar.
  final barFocus = FocusNode(debugLabel: 'canvas note bar');

  CanvasDocument get _document => engine.document;
  bool get active => session != null;

  bool _blocked() => spectating() || canvasErrorBlocksDrawing(engine.error);

  /// Opens the note [id] for typing, unless it is locked or the canvas is refusing writes.
  void edit(String id) {
    if (_blocked()) return;
    if (engine.ops.isLocked(id)) {
      engine.reportError('That note is locked.');
      return;
    }
    final bounds = _document.objectBounds(id);
    final text = _document.noteTextOf(id);
    if (bounds == null || text == null) return;
    _open(
      CanvasNoteEditSession(
        objectId: id,
        initialText: text,
        startBounds: bounds,
      ),
    );
  }

  /// Opens a draft note at [world] in the style last used; nothing is sent until its text is committed.
  void placeDraft(Offset world, [Size? draggedSize]) {
    if (!_blocked()) _openDraft(world, draggedSize, '');
  }

  void _openDraft(Offset world, Size? draggedSize, String text) {
    final width = draggedSize?.width ?? defaultNoteWidth;
    final height = draggedSize?.height ?? defaultNoteHeight;
    final box = _document.placeOnBoard(
      Rect.fromCenter(center: world, width: width, height: height),
    );
    final id = 'draft-${newCanvasObjectId()}';
    _document
      ..applyPlaced(
        CanvasStrokeInput(
          id: id,
          seq: 0,
          zIndex: provisionalLocalZIndex,
          x: box.left,
          y: box.top,
          w: box.width,
          h: box.height,
          points: const [],
          width: 0,
          colorKey: 'note',
          kind: CanvasObjectKind.note,
          text: text,
          noteStyle: ref.read(canvasLastNoteStyleProvider),
        ),
      )
      ..selectedObjectId.value = id
      ..refresh();
    _open(
      CanvasNoteEditSession(
        objectId: id,
        initialText: text,
        startBounds: (x: box.left, y: box.top, w: box.width, h: box.height),
        draft: CanvasNoteDraft(world: world, draggedSize: draggedSize),
      ),
    );
  }

  void _open(CanvasNoteEditSession next) => changed(() => session = next);

  void _close() {
    final closing = session;
    changed(() => session = null);
    focusBoard();
    if (closing == null) return;
    // After the frame that removes the editor, which still listens to the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => closing.dispose());
  }

  /// Puts the note back to the box it had before typing grew it.
  void _restoreBounds(CanvasNoteEditSession s) {
    final b = s.startBounds;
    _document
      ..moveObject(s.objectId, b.x, b.y, b.w, b.h)
      ..refresh();
  }

  void cancel() {
    final s = session;
    if (s == null) return;
    if (s.draft != null) {
      _document
        ..removeObject(s.objectId)
        ..selectedObjectId.value = null
        ..refresh();
    } else {
      _restoreBounds(s);
    }
    _close();
  }

  /// The note was removed by someone else while it was open.
  void gone() {
    engine.reportError('That note was removed while you were editing it.');
    _close();
  }

  Future<void> commit(String text) async {
    final s = session;
    if (s == null) return;
    final draft = s.draft;
    if (draft != null) return _commitDraft(s, draft, text);
    _restoreBounds(s);
    // Stays open when the edit is refused, with the reason on the canvas.
    final done = await engine.ops.editNote(s.objectId, text);
    if (!identical(session, s)) return;
    if (done) {
      _close();
    } else {
      _document.moveObject(
        s.objectId,
        s.startBounds.x,
        s.startBounds.y,
        s.startBounds.w,
        s.startBounds.h,
      );
      changed();
    }
  }

  Future<void> _commitDraft(
    CanvasNoteEditSession s,
    CanvasNoteDraft draft,
    String text,
  ) async {
    final started = currentTool();
    final style = _document.noteStyleOf(s.objectId) ?? const CanvasNoteStyle();
    _document
      ..removeObject(s.objectId)
      ..selectedObjectId.value = null
      ..refresh();
    _close();
    final placed = await placement().placeNote(
      draft.world,
      text,
      draggedSize: draft.draggedSize,
      style: style,
      onError: engine.reportError,
    );
    if (placed != null) {
      onPlaced(placed.id, started);
      return;
    }
    // Typed text outlives a failed placement: the draft opens again with it.
    _openDraft(draft.world, draft.draggedSize, text);
    _document.setNoteStyle(session!.objectId, style);
  }

  /// The style bar and, while one is open, the note's own field, filling the pane over the board.
  Widget overlay({
    required AppTokens tokens,
    required CanvasTool tool,
    required bool Function(String id) mayEdit,
    required void Function(String id, {String? size, String? colorKey})
    onTextStyle,
    bool textEditing = false,
    Widget? textEditor,
  }) {
    final open = session;
    return Positioned.fill(
      child: Stack(
        children: [
          CanvasNoteBarLayer(
            document: _document,
            tool: tool,
            session: open,
            mayEdit: (id) => !engine.ops.isLocked(id) && mayEdit(id),
            onStyle: restyle,
            onTextStyle: onTextStyle,
            textEditing: textEditing,
            focus: barFocus,
          ),
          if (open != null)
            CanvasNoteEditor(
              key: ValueKey(open.objectId),
              document: _document,
              session: open,
              palette: canvasNotePalette(tokens),
              onCommit: (text) => unawaited(commit(text)),
              onCancel: cancel,
              onGone: gone,
            ),
          ?textEditor,
        ],
      ),
    );
  }

  /// Selects the note [id] and puts the keyboard on its style bar.
  void focusBar(String id) {
    _document.selectedObjectId.value = id;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => barFocus.requestFocus(),
    );
  }

  /// Applies a style from the bar: a draft just shows it, a placed note sends one edit.
  void restyle(String id, CanvasNoteStyle next) {
    ref.read(canvasLastNoteStyleProvider.notifier).state = next;
    if (session?.draft != null && session?.objectId == id) {
      _document
        ..setNoteStyle(id, next)
        ..refresh();
      changed();
      return;
    }
    unawaited(engine.ops.styleNote(id, next).then((_) => changed()));
  }
}
