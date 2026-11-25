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
import '../../composer/widgets/composer_shortcode_convert.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../providers/canvas_edge_style.dart';
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
    required this.onEscaped,
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

  /// Runs after Escape cancels the edit.
  final VoidCallback onEscaped;

  CanvasNoteEditSession? session;

  /// Where the keyboard lands when the object menu asks for the style bar.
  final barFocus = FocusNode(debugLabel: 'canvas note bar');

  bool _disposed = false;

  /// Reports a change to the pane unless it is being torn down, when there is no state left to rebuild.
  void _apply([VoidCallback? mutate]) =>
      _disposed ? mutate?.call() : changed(mutate);

  Map<String, String> _lastEmojiIndex = const {};

  /// The custom emoji as last read: a pane closing still sends what was typed, once its ref is gone.
  Map<String, String> _emojiIndex() => _disposed
      ? _lastEmojiIndex
      : _lastEmojiIndex = ref.read(customEmojiIndexProvider);

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
        emojiIndex: _emojiIndex,
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
          noteStyle: ref.read(canvasNoteStyleSupportedProvider)
              ? ref.read(canvasLastNoteStyleProvider)
              : const CanvasNoteStyle(),
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
        emojiIndex: _emojiIndex,
      ),
    );
  }

  void _open(CanvasNoteEditSession next) => _apply(() => session = next);

  void _close() {
    final closing = session;
    _apply(() => session = null);
    if (!_disposed) focusBoard();
    if (closing == null) return;
    // After the frame that removes the editor, which still listens to the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => closing.dispose());
  }

  /// Gives back only the height typing added, so a move or resize by someone else stays.
  void _restoreBounds(CanvasNoteEditSession s) {
    final now = _document.objectBounds(s.objectId);
    if (now == null || now.h != s.grownHeight) return;
    _document
      ..moveObject(s.objectId, now.x, now.y, now.w, s.baseHeight)
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

  /// The note left the board while it was open: a draft is opened again with its text, which a hard reset must not cost.
  void gone() {
    final s = session;
    final draft = s?.draft;
    if (s != null && draft != null) {
      final text = s.controller.text;
      _close();
      _openDraft(draft.world, draft.draggedSize, text);
      return;
    }
    engine.reportError('That note was removed while you were editing it.');
    _close();
  }

  /// The pane is closing: what was typed is sent, never dropped.
  void dispose() {
    _disposed = true;
    final s = session;
    if (s != null) {
      final text = s.controller.text.trim();
      if (text.isEmpty || text == s.initialText) {
        cancel();
      } else {
        unawaited(commit(text));
      }
    }
    barFocus.dispose();
  }

  Future<void> commit(String typed) async {
    final s = session;
    if (s == null) return;
    final text = canonicalCustomEmojiText(typed, _emojiIndex());
    final draft = s.draft;
    if (draft != null) return _commitDraft(s, draft, text);
    _restoreBounds(s);
    // Stays open when the edit is refused, with the reason on the canvas.
    final done = await engine.ops.editNote(s.objectId, text);
    if (!identical(session, s)) return;
    if (done) {
      _close();
    } else {
      final now = _document.objectBounds(s.objectId);
      final grown = s.grownHeight;
      if (now != null && grown != null && now.h == s.baseHeight) {
        _document.moveObject(s.objectId, now.x, now.y, now.w, grown);
      }
      _apply();
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
            // The person typing a draft owns it, whatever the board would say of an object with no author yet.
            mayEdit: (id) =>
                (open?.draft != null && open?.objectId == id) ||
                (!engine.ops.isLocked(id) && mayEdit(id)),
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
              onCancel: () {
                cancel();
                onEscaped();
              },
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
    unawaited(engine.ops.styleNote(id, next).then((_) => _apply()));
  }
}
